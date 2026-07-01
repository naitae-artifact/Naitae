---
title: IndexingTree GC integration — flag-based vs WeakObjArrayKlass
tags: [jdk, gc, indexing-tree, design]
---

# IndexingTree GC integration: flag-based vs WeakObjArrayKlass

Both implementations solve the same problem: make the bucket array of
`java.lang.rv.IndexingTree` invisible to GC tracing during selected
phases, so entries don't keep their keys alive through the tree.

They share the same phase-tracking machinery (`WeakArrayScanScope`),
the same cleanup algorithm (`IndexingTreeManager`), and the same
`ReferenceProcessor` hook. They differ in **how a particular array is
recognized as the bucket array**.

**Summary**

- **Flag-based**: per-instance `bool` on `ObjArrayKlass`. Stock obj-array iterate is patched to check it.
- **Klass-based**: distinct `KlassKind` for the bucket-array klass. Stock obj-array iterate is untouched.

---

## Shared machinery

Whatever recognition mechanism we pick, the rest is the same.

### Phase tracking — `WeakArrayScanScope`

A global `uint8_t` bitmask. RAII scopes set/clear bits at collector
phase boundaries. Every consumer reads it via `WeakArrayScanScope::in(Mode)`.

```cpp
// src/hotspot/share/gc/shared/weakArrayScanScope.hpp
class WeakArrayScanScope : public StackObj {
 public:
  enum Mode : uint8_t {
    None       = 0,
    YoungScan  = 1 << 0,
    StrongMark = 1 << 1,
    G1Mixed    = 1 << 2,
  };
  explicit WeakArrayScanScope(uint8_t modes);
  ~WeakArrayScanScope();
  static bool in(Mode m);
  static void enter(Mode m);    // non-RAII for G1 concurrent mark
  static void leave(Mode m);
};
```

```cpp
// weakArrayScanScope.cpp
WeakArrayScanScope::WeakArrayScanScope(uint8_t modes) {
  _added = modes & ~_composite_mode;
  _composite_mode |= modes;
}
WeakArrayScanScope::~WeakArrayScanScope() {
  _composite_mode &= ~_added;
}
```

Bits compose; dtor clears only the bits the ctor added, so nesting
(young inside mixed, etc.) is safe.

### Where the scope is set

Every collector wraps its phase in a scope. This is the **only** way
the rest of the code knows what phase the GC is in.

```cpp
// serial/defNewGeneration.cpp:781
WeakArrayScanScope _weak_scope(IndexingTreeYoungGC ? WeakArrayScanScope::YoungScan
                                                  : WeakArrayScanScope::None);

// serial/genMarkSweep.cpp:169
WeakArrayScanScope _weak_scope(WeakArrayScanScope::StrongMark);

// parallel/psScavenge.cpp:463
WeakArrayScanScope _weak_scope(IndexingTreeYoungGC ? WeakArrayScanScope::YoungScan
                                                  : WeakArrayScanScope::None);

// parallel/psParallelCompact.cpp:2031
WeakArrayScanScope _weak_scope(WeakArrayScanScope::StrongMark);

// g1/g1FullCollector.cpp:294
WeakArrayScanScope _weak_scope(WeakArrayScanScope::StrongMark);

// g1/g1YoungCollector.cpp:1066 — composite (young + mixed)
uint8_t _modes = WeakArrayScanScope::None;
if (IndexingTreeYoungGC) {
  _modes = WeakArrayScanScope::YoungScan;
  if (collector_state()->in_mixed_phase()) _modes |= WeakArrayScanScope::G1Mixed;
}
WeakArrayScanScope _weak_scope(_modes);

// g1/g1ConcurrentMark.cpp:1039 / :1653 — non-RAII (crosses thread/frame)
WeakArrayScanScope::enter(WeakArrayScanScope::StrongMark);
...
WeakArrayScanScope::leave(WeakArrayScanScope::StrongMark);
```

### Cleanup gate

```cpp
// shared/referenceProcessor.cpp:264
if (WeakArrayScanScope::in(WeakArrayScanScope::StrongMark) ||
    WeakArrayScanScope::in(WeakArrayScanScope::YoungScan)) {
  IndexingTreeCleanupTask idx_task(*this);
  ...
}
```

### Per-collector chunking gates

Some collectors have manual slot loops that bypass klass dispatch.
Each one needs an explicit gate. The recognition predicate
(`is_indexing_tree_table()` vs `is_weak_objArray_klass()`) is the only
thing that differs between implementations.

```cpp
// parallel/psPromotionManager.inline.hpp — don't chunk our arrays
if (RECOGNIZE(a->klass())) push_contents(a);

// parallel/psPromotionManager.cpp — defense for stolen chunk tasks
if (WeakArrayScanScope::in(WeakArrayScanScope::YoungScan) &&
    RECOGNIZE(a->klass())) return;

// parallel/psCompactionManager.inline.hpp — Parallel full GC follow_array
if (RECOGNIZE(klass) &&
    WeakArrayScanScope::in(WeakArrayScanScope::StrongMark)) return;
```

---

## Old: flag-based recognition

A `bool` field on `ObjArrayKlass`. Bucket arrays get the flag set; all
other obj arrays leave it `false`.

### Klass change

```cpp
// ablation-flag-fixed/src/hotspot/share/oops/objArrayKlass.hpp:54
class ObjArrayKlass : public ArrayKlass {
  ...
  bool _is_indexing_tree_table;
  ...
 public:
  bool is_indexing_tree_table() const      { return _is_indexing_tree_table; }
  void set_is_indexing_tree_table(bool v)  { _is_indexing_tree_table = v; }
};

// objArrayKlass.cpp:142 — initialize false
_is_indexing_tree_table = false;
```

### Set point

After allocating the bucket array, mark its klass:

```cpp
// jvm.cpp:640
ObjArrayKlass::cast(array_klass)->set_is_indexing_tree_table(true);
```

There's only one `IndexingTreeEntry[]` array klass per JVM, so this
runs once.

### Suppression predicate — patched into stock iterate

```cpp
// ablation-flag-fixed/src/hotspot/share/oops/objArrayKlass.inline.hpp:45
template <class OopClosureType>
static inline bool objarray_skip_as_indexing_tree(ObjArrayKlass* k,
                                                  OopClosureType* closure) {
  if (!k->is_indexing_tree_table()) return false;        // ← runs for ALL obj arrays
  using S = WeakArrayScanScope;
  if (S::in(S::YoungScan)) return true;
  if (S::in(S::StrongMark) &&
      closure->reference_iteration_mode() == OopIterateClosure::DO_DISCOVERY) {
    return true;
  }
  return false;
}

// objArrayKlass.inline.hpp:97 — gate inserted at the top
template <typename T, typename OopClosureType>
void ObjArrayKlass::oop_oop_iterate(oop obj, OopClosureType* closure) {
  objArrayOop a = objArrayOop(obj);
  if (Devirtualizer::do_metadata(closure)) Devirtualizer::do_klass(closure, obj->klass());
  if (objarray_skip_as_indexing_tree(this, closure)) return;
  oop_oop_iterate_elements<T>(a, closure);
}
```

**Stock obj-array iterate is patched.** Every iteration of every
object array in the JVM now does an extra load + compare on
`_is_indexing_tree_table`. The bool is `false` for everything except
our one array klass, so the branch almost always falls through — but
the cost is non-zero.

### Allocation — install-once flag race

The flag has to be set on `ObjArrayKlass` *before* anything else
resolves `[Ljava/lang/rv/IndexingTreeEntry;`. If JIT/verifier/reflection
gets there first, the array klass gets cached as a plain
`ObjArrayKlass`, and trying to set the flag later either asserts or
silently does nothing depending on how the cache is keyed.

The implementation uses an `_creates_weak_arrays` flag on
`InstanceKlass` that the cache install path reads. Robust only if the
*first* resolve of the array klass goes through our path.

---

## Current: WeakObjArrayKlass

A new klass type, subclass of `ObjArrayKlass`. The bucket array klass
*is* a `WeakObjArrayKlass`. Recognition is by klass identity, dispatch
by the existing `KlassKind` machinery.

### Klass change

```cpp
// src/hotspot/share/oops/klass.hpp
enum KlassKind {
  ...
  ObjArrayKlassKind,
  WeakObjArrayKlassKind,    // ← new
  UnknownKlassKind
};

// klass.hpp predicates
bool is_objArray_klass()       { ... ObjArrayKlassKind || WeakObjArrayKlassKind ... }
bool is_weak_objArray_klass()  { return _kind == WeakObjArrayKlassKind; }
```

```cpp
// src/hotspot/share/oops/weakObjArrayKlass.hpp
class WeakObjArrayKlass : public ObjArrayKlass {
 public:
  static const KlassKind Kind = WeakObjArrayKlassKind;
  ...
  template <typename T, class OopClosureType>
  void oop_oop_iterate(oop obj, OopClosureType* closure);
  ...
};
```

### Suppression predicate — its own iterate, stock untouched

```cpp
// src/hotspot/share/oops/weakObjArrayKlass.inline.hpp
template <class OopClosureType>
static inline bool weak_objarray_suppress(OopClosureType* closure) {
  using S = WeakArrayScanScope;
  if (S::in(S::YoungScan)) return true;
  if (S::in(S::StrongMark) &&
      closure->reference_iteration_mode() == OopIterateClosure::DO_DISCOVERY) {
    return true;
  }
  return false;
}

template <typename T, class OopClosureType>
void WeakObjArrayKlass::oop_oop_iterate(oop obj, OopClosureType* closure) {
  objArrayOop a = objArrayOop(obj);
  if (Devirtualizer::do_metadata(closure)) Devirtualizer::do_klass(closure, obj->klass());
  if (weak_objarray_suppress(closure)) return;
  ObjArrayKlass::oop_oop_iterate_elements<T>(a, closure);
}
```

`ObjArrayKlass::oop_oop_iterate` is **unchanged from upstream**.
Dispatch goes through `OopOopIterateDispatch`, which routes by
`KlassKind` — so only `WeakObjArrayKlass`-kinded arrays hit
`weak_objarray_suppress`.

### Allocation — explicit factory, no install-once race

```java
// src/java.base/share/classes/java/lang/rv/WeakObjArray.java
public final class WeakObjArray {
    public static native Object[] allocate(int length);
}
```

```cpp
// src/hotspot/share/prims/jvm.cpp:662
JVM_ENTRY(jobjectArray, JVM_WeakObjArrayAllocate(JNIEnv*, jclass, jint length))
  WeakObjArrayKlass* k = get_or_create_weak_array_klass(
      vmSymbols::java_lang_Object(), &_object_weak_array_klass, CHECK_NULL);
  objArrayOop arr = ObjArrayKlass::cast(k)->allocate(length, CHECK_NULL);
  return (jobjectArray) JNIHandles::make_local(THREAD, arr);
JVM_END
```

The factory always returns a `WeakObjArrayKlass`-typed array. There's
no flag to set late; nothing else can resolve our array klass first
because the only path to it is `WeakObjArray.allocate`.

### Dispatch registration

The new klass kind has to appear in three `OopOopIterateDispatch`
initializer sites — missing any one silently mis-routes traversal.

```cpp
// src/hotspot/share/memory/iterator.inline.hpp  (three sites)
table->set_resolve_function_and_execute_optimized<WeakObjArrayKlass>(...);
```

---

## Recognition predicate per implementation

The chunking gates and `IndexingTreeManager` need a predicate to ask
"is this *our* array?" The body of the gates is the same in both
versions; only the predicate name differs.

| Site | Flag-based | Klass-based |
|---|---|---|
| `psPromotionManager.inline.hpp` | `k->is_indexing_tree_table()` | `k->is_weak_objArray_klass()` |
| `psPromotionManager.cpp` | same | same |
| `psCompactionManager.inline.hpp` | same | same |

---

## Side-by-side

| Aspect | Flag-based | WeakObjArrayKlass |
|---|---|---|
| Recognition | `bool _is_indexing_tree_table` per `ObjArrayKlass` | Distinct `KlassKind` |
| Dispatch | Patched stock `ObjArrayKlass::oop_oop_iterate` | New klass adds its own dispatch slot |
| Cost on non-tree arrays | Load + compare on every iterate | Zero — different dispatch entry |
| Stock GC code touched | `ObjArrayKlass::oop_oop_iterate` body | None |
| Allocation | First `array_klass()` call must go through our path; install-once flag race | Explicit `WeakObjArray.allocate(n)` factory |
| Failure mode if missetup | Bucket array silently treated as plain `ObjArrayKlass`, weak semantics lost | Cannot misallocate — factory always returns the right klass |
| Phase tracking | `WeakArrayScanScope` | `WeakArrayScanScope` (same) |
| Cleanup logic | `IndexingTreeManager` | `IndexingTreeManager` (same) |
| `ReferenceProcessor` hook | Same | Same |
| Per-collector chunking gates | `is_indexing_tree_table()` | `is_weak_objArray_klass()` |
| LOC delta vs upstream | Smaller (one bool, one predicate, one patched iterate) | Larger (new klass, new files, dispatch registrations) |

---

## How phase detection works (both impls)

Same answer in both: read `WeakArrayScanScope::current()`.

```text
collector phase entry
   |
   |  WeakArrayScanScope _weak_scope(YoungScan | G1Mixed | ...)
   |       |
   |       v
   |  _composite_mode |= modes      ← single global uint8_t
   |
   v
GC tracing runs
   |
   v
suppression predicate reads WeakArrayScanScope::in(YoungScan) etc.
   |
   v
ReferenceProcessor::process_discovered_references reads it again
to decide whether to run cleanup
   |
   v
collector phase exit
   |
   |  ~WeakArrayScanScope()
   |       |
   |       v
   |  _composite_mode &= ~_added    ← clears only what this scope set
```

No virtuals, no callbacks, no GC-internal events. The only way the
rest of the JVM learns "we are in a young GC" is by checking this
bitmask.

---

## The resize safepoint bug

Once the bucket array is `WeakObjArrayKlass`-typed, the table loses
its strong-edge-from-mutator-roots property *during* GC phases that
suppress it. That makes one specific Java idiom unsafe:
**resize-then-publish.**

### What broke

The original `IndexingTree.adjustCapacity` was a plain Java method:

```java
// (paraphrased original — Java rehash)
void adjustCapacity(int newCapacity) {
    IndexingTreeEntry[] staging = new IndexingTreeEntry[newCapacity];   // ← WeakObjArrayKlass-typed
    for (int i = 0; i < table.length; i++) {
        IndexingTreeEntry e = table[i];
        while (e != null) {
            IndexingTreeEntry next = e.next;
            int idx = (e.hashCode & 0x7fffffff) % newCapacity;
            e.next = staging[idx];
            staging[idx] = e;
            e = next;
        }
    }
    table = staging;        // publish
    capacity = newCapacity;
}
```

The new array is `IndexingTreeEntry[]` and so is allocated as
`WeakObjArrayKlass`-typed. While the rehash loop runs, every entry
that has been moved lives in `staging` only — `staging` is a local
on the rehashing thread's stack and is **not yet stored in
`tree.table`**.

The `new IndexingTreeEntry[]` allocation can safepoint. If a young GC
fires inside that window:

1. Mutator roots see `staging` as a stack root — array stays alive.
2. GC walks `staging` via `WeakObjArrayKlass::oop_oop_iterate`.
3. `WeakArrayScanScope::in(YoungScan)` is true → predicate suppresses → **slots not visited.**
4. Card scanning of `staging` is also suppressed (same predicate).
5. Entries that have been moved into `staging` have no other live root: the old `table` cleared them, the rehashing thread is between iterations.
6. Young GC reclaims those entries.
7. `staging[idx]` slots now point into reclaimed young-gen memory.
8. The mutator resumes the rehash loop, dereferences `staging[idx]` → SEGV. Or worse, a later full GC compacts using the corrupt oops and writes garbage everywhere.

Symptoms in the field: G1 pmd at `-Xmx` near the rehash threshold,
`9/30` runs crashing in mutator chain walks or `psParallelCompact`.

### Why this is the WeakObjArrayKlass story (not a generic rehash bug)

A normal Java hash-map rehash has the same shape and is safe — the
staging array's slots are strongly traced as ordinary
`ObjArrayKlass` slots, so moved entries stay alive via the staging
array regardless of where it lives in memory. The bug only exists
because *we asked* GC to skip element scanning of the bucket array,
and the original Java rehash was written without knowing that the
array it produces has weak-element semantics during young GC.

### The fix — atomic JNI transaction

Move the whole resize into a JNI call and wrap the dangerous part in
`NoSafepointVerifier`. Allocation can still safepoint (no way to
avoid that), but the actual entry move and the publish all happen in
a single safepoint-free section.

```cpp
// src/hotspot/share/prims/jvm.cpp:691
JVM_ENTRY(void, JVM_IndexingTreeAdjustCapacity(JNIEnv* env, jobject this_jobj,
                                                jint new_capacity,
                                                jint new_up,
                                                jint new_down))
  Handle tree_h(THREAD, JNIHandles::resolve_non_null(this_jobj));

  // Allocation may safepoint; tree_h keeps `tree` valid across it.  The
  // new table is empty at this point — even if a young GC fires here,
  // no entries are inside the staging array yet, so suppression is fine.
  objArrayOop new_table_raw = alloc_indexing_table(new_capacity, CHECK);
  Handle new_table_h(THREAD, new_table_raw);

  {
    NoSafepointVerifier nsv;          // ← no GC from here to the publish
    ResourceMark rm(THREAD);

    oop tree = tree_h();
    objArrayOop old_table = java_lang_rv_IndexingTree::table(tree);
    int old_capacity = java_lang_rv_IndexingTree::capacity_value(tree);
    objArrayOop new_table = (objArrayOop) new_table_h();

    oop* tails = NEW_RESOURCE_ARRAY(oop, new_capacity);
    for (int i = 0; i < new_capacity; i++) tails[i] = nullptr;

    // Move every chain old → new.
    for (int i = old_capacity - 1; i >= 0; i--) {
      oop entry = old_table->obj_at(i);
      if (entry == nullptr) continue;
      old_table->obj_at_put(i, nullptr);
      while (entry != nullptr) {
        oop next  = java_lang_rv_IndexingTreeEntry::next(entry);
        int hash  = java_lang_rv_IndexingTreeEntry::entry_hashCode(entry);
        int idx   = (hash & 0x7fffffff) % new_capacity;
        java_lang_rv_IndexingTreeEntry::set_next(entry, (oop)nullptr);
        if (new_table->obj_at(idx) == nullptr) {
          new_table->obj_at_put(idx, entry);
        } else {
          java_lang_rv_IndexingTreeEntry::set_next(tails[idx], entry);
        }
        tails[idx] = entry;
        entry = next;
      }
    }

    // Publish capacity / thresholds / table together — all four field
    // stores are within the same NSV section, so no GC observes a
    // mid-resize tree.
    java_lang_rv_IndexingTree::set_capacity(tree, new_capacity);
    java_lang_rv_IndexingTree::set_upThreshold(tree, new_up);
    java_lang_rv_IndexingTree::set_downThreshold(tree, new_down);
    java_lang_rv_IndexingTree::set_table(tree, new_table);
  }
JVM_END
```

Why this works:

- `NoSafepointVerifier` asserts no safepoint can fire in the marked region. With no GC, the staging array's suppression is irrelevant — nothing is going to try to walk it weakly.
- Entries are moved old→new in one contiguous sequence; at every observable point (i.e. every safepoint), an entry is in *exactly one* table.
- The four field stores at the bottom (`capacity`, `upThreshold`, `downThreshold`, `table`) are atomic with respect to GC because they're inside the same NSV section. No collector ever sees a tree whose `capacity` has changed but `table` hasn't, or vice-versa.
- Allocation (`alloc_indexing_table`) is *outside* the NSV section. That's fine — at allocation time the new table is empty, so even a young GC firing on the alloc safepoint has nothing to lose.

### Validation

From the commit message (commit `fbc73a720`, 30-run pmd batches against the no-sync baseline):

```
g1       : 9/30 -> 0/30 crashes
parallel : 0/30 -> 0/30
sunflow  : 0/N  -> 0/10 (parallel and g1)
```

Performance within run-to-run noise; functional output (violation
counts) is bit-equivalent to the Java baseline.

### Generalization

Anywhere a `WeakObjArrayKlass`-typed array is used as a *staging*
location — i.e. populated before being installed in a strongly-traced
field — the population must run inside a no-safepoint section, or
the same bug recurs. Resize is the only place this currently happens
in `IndexingTree`. The Java-side `allocateTable` path is fine because
the array is empty when allocation returns and is published before
any entry moves into it.

---

## Why the migration

Two reasons.

**Cost.** The flag-based predicate runs on every object-array
iteration in the entire JVM. Most arrays aren't ours, so the branch
is predictable, but the load and compare are unavoidable.
`WeakObjArrayKlass` moves recognition into the dispatch table — stock
obj arrays never see the predicate at all.

**Allocation correctness.** The flag-based version depends on the
*first* resolve of `[Ljava/lang/rv/IndexingTreeEntry;` going through
our allocation path. JIT, verifier, or reflection can race ahead and
cache a plain `ObjArrayKlass` first, after which the flag never gets
set. `WeakObjArrayKlass` removes the race — the array klass is what
we say it is, because the only way to allocate it is our factory.

The cost-on-non-tree-arrays argument is what shows up in benchmarks;
the allocation-race argument is what shows up as a heisenbug.

---

## What didn't change in the migration

- `WeakArrayScanScope` and every collector's scope-push site
- `IndexingTreeManager` (Phase 1 / Phase 2 cleanup)
- `ReferenceProcessor::process_discovered_references` cleanup hook
- Per-collector chunking gates (only the predicate name changed)
- The Java-side `IndexingTree` / `IndexingTreeEntry` API

The migration was purely a recognition-mechanism swap. If you're
reading old commits, the cleanup code is byte-identical to the new
version; the diffs are concentrated in `oops/` and `prims/jvm.cpp`.
