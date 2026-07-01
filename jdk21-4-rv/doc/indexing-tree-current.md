## Branch: `jdk21-rv-young-gc-fix`

Identity-keyed hash table for RV-Monitor with weak-key semantics, no
`WeakReference`, no `ReferenceQueue`. Bucket array is a special klass
the GC skips during selected phases; cleanup runs at safepoint after
ref processing.

### Layout

```
java.lang.rv.IndexingTree
  table : Object[]                 ← WeakObjArrayKlass-typed
            ↓
          IndexingTreeEntry        ← chain node
            keys[]   : Object[]
            value    : Object       (monitor / set / tuple)
            next     : IndexingTreeEntry
            hashCode : int
```

Java side: [IndexingTree.java](src/java.base/share/classes/java/lang/rv/IndexingTree.java),
[IndexingTreeEntry.java](src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java).
Public methods are `synchronized`; resize is one JNI transaction
([JVM_IndexingTreeAdjustCapacity](src/hotspot/share/prims/jvm.cpp#L691)).

### Allocating the bucket array

Two layers — generic factory and tree-specific entry point.

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

// jvm.cpp:670 — IndexingTree-specific: alloc + register in one JNI call
JVM_ENTRY(void, JVM_IndexingTreeInit(JNIEnv*, jobject tree, jint capacity))
  Handle tree_h(THREAD, JNIHandles::resolve_non_null(tree));
  objArrayOop arr = alloc_indexing_table(capacity, CHECK);
  java_lang_rv_IndexingTree::set_table(tree_h(), arr);
  IndexingTreeManager::add_tree(tree_h());
JVM_END
```

> Earlier design used `InstanceKlass::_creates_weak_arrays` as an
> install-once flag to switch the array klass on `IndexingTreeEntry`'s
> first array-klass resolve. Removed in `31ff6e32a` — replaced with the
> explicit static factory above. No more race against JIT/verifier
> resolving `[Ljava/lang/rv/IndexingTreeEntry;` first.

### WeakObjArrayKlass

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

`KlassKind` plumbing: `WeakObjArrayKlassKind` registered in
[klass.hpp](src/hotspot/share/oops/klass.hpp), all three
`OopOopIterateDispatch` initializers in
[iterator.inline.hpp](src/hotspot/share/memory/iterator.inline.hpp),
`is_objArray_klass()` matches both kinds, `is_weak_objArray_klass()`
matches only the weak one.

### WeakArrayScanScope

```cpp
// src/hotspot/share/gc/shared/weakArrayScanScope.hpp
class WeakArrayScanScope : public StackObj {
 public:
  enum Mode : uint8_t {
    None       = 0,
    YoungScan  = 1 << 0,   // young scavenge / card scan
    StrongMark = 1 << 1,   // full-GC DO_DISCOVERY marking
    G1Mixed    = 1 << 2,   // G1 mixed pause
  };
  explicit WeakArrayScanScope(uint8_t modes);
  ~WeakArrayScanScope();
  static uint8_t current();
  static bool    in(Mode m);
  static void enter(Mode m);   // G1 concurrent mark uses these — scope
  static void leave(Mode m);   // crosses thread/frame boundaries.
};
```

Bits compose, dtor clears only what the ctor set, so nesting is safe.

### Cleanup — `IndexingTreeManager`

```cpp
// src/hotspot/share/utilities/indexingTreeManager.hpp
class IndexingTreeManager : AllStatic {
  static OopStorage* _tree_storage;                      // strong
  static GrowableArrayCHeap<oop*, mtGC>* _tree_slots;    // flat slot index
  static Mutex* _slots_lock;                             // mutator add_tree only

 public:
  static void clean_tree(oop tree, BoolObjectClosure* is_alive,
                         OopClosure* keep_alive, VoidClosure* complete_gc);

  // Single-threaded (Serial, single-tree workloads).
  static void clean_all_trees(BoolObjectClosure*, OopClosure*, VoidClosure*);

  // Multi-worker — every worker passes the SAME counter; granularity =
  // one tree per claim.  Avoids OopStorage's coarser per-block claim.
  static void clean_trees_par_indexed(volatile uint* counter,
                                      BoolObjectClosure*, OopClosure*, VoidClosure*);

  // Mark-only (Shenandoah, ZGC: marks already complete, no keep_alive).
  static void clean_all_trees_marked(BoolObjectClosure*);
  static void clean_trees_marked_par_indexed(volatile uint*, BoolObjectClosure*);
};
```

Two phases per tree:

```cpp
// indexingTreeManager.cpp:75 — Phase 1: unlink dead entries
static void clean_bucket_range(objArrayOop table_array, int start, int end,
                               BoolObjectClosure* is_alive,
                               int& dead_out, int& alive_out) {
  for (int i = start; i < end; i++) {
    oop prev = nullptr, entry = table_array->obj_at(i), first_alive = nullptr;
    bool bucket_changed = false;
    while (entry != nullptr) {
      oop next_entry = java_lang_rv_IndexingTreeEntry::next(entry);
      objArrayOop keys = java_lang_rv_IndexingTreeEntry::keys(entry);
      bool all_keys_alive = true;
      if (keys != nullptr) {
        for (int k = 0; k < keys->length(); k++) {
          if (!key_is_alive(keys->obj_at(k), is_alive)) { all_keys_alive = false; break; }
        }
      }
      if (all_keys_alive) {
        if (first_alive == nullptr) first_alive = entry;
        if (prev != nullptr && java_lang_rv_IndexingTreeEntry::next(prev) != entry) {
          java_lang_rv_IndexingTreeEntry::set_next(prev, entry);
          bucket_changed = true;
        }
        prev = entry;
      } else {
        bucket_changed = true;
      }
      entry = next_entry;
    }
    if (bucket_changed) {
      if (prev != nullptr) java_lang_rv_IndexingTreeEntry::set_next(prev, (oop)nullptr);
      table_array->obj_at_put(i, first_alive);   // only writes when chain changed
    }
  }
}
```

```cpp
// indexingTreeManager.cpp:160 — Phase 2: keep_alive every surviving bucket head.
// Drain every IndexingTreeDrainInterval (256) refs to bound mark-stack depth.
for (int i = 0; i < table_length; i++) {
  if (table_array->obj_at(i) == nullptr) continue;
  if (UseCompressedOops) keep_alive->do_oop(&((narrowOop*)table_array->base())[i]);
  else                   keep_alive->do_oop(&((oop*)table_array->base())[i]);
  if (++refs_since_drain >= IndexingTreeDrainInterval) {
    if (complete_gc != nullptr) complete_gc->do_void();
    refs_since_drain = 0;
  }
}
```

Full GC also keeps the table field alive before Phase 2 (otherwise sweep
reclaims the array itself):

```cpp
// indexingTreeManager.cpp:145
if (!is_young_gc) {
  if (UseCompressedOops) keep_table_field_alive<narrowOop>(tree, keep_alive);
  else                   keep_table_field_alive<oop>(tree, keep_alive);
  if (complete_gc != nullptr) complete_gc->do_void();
  table_array = java_lang_rv_IndexingTree::table(tree);   // re-read; full GC may have moved it
}
```

### Conservative keep-alive: YoungScan ∩ StrongMark

G1 young pause interleaved with concurrent mark. Key liveness is
unknowable mid-mark, but we still have to root every entry — otherwise
young-gen entries reachable only via the suppressed bucket array slots
have no live root and the young GC reclaims them, leaving dangling
slots that crash the next non-interleaved cleanup.

```cpp
// indexingTreeManager.cpp:181
bool young_gc = WeakArrayScanScope::in(WeakArrayScanScope::YoungScan);
if (young_gc && WeakArrayScanScope::in(WeakArrayScanScope::StrongMark)) {
  for (int i = 0; i < table_length; i++) {
    if (table_array->obj_at(i) == nullptr) continue;
    if (UseCompressedOops) keep_alive->do_oop(&((narrowOop*)table_array->base())[i]);
    else                   keep_alive->do_oop(&((oop*)table_array->base())[i]);
  }
  if (complete_gc != nullptr) complete_gc->do_void();
  return;   // defer pruning to the next non-interleaved cleanup
}
```

Repro that produced the original SEGV: `g1 + fop -Xmx8g` — Pause Young
(Concurrent Start) → Concurrent Mark begins → interleaved Pause Young
(Normal) → Concurrent Mark ends → next Pause Young (Prepare Mixed)
crashes reading `keys->length()` from a dangling slot.

### Parallel cleanup driver

Cleanup runs as a `RefProcTask` after phantom-refs processing.

```cpp
// src/hotspot/share/gc/shared/referenceProcessor.cpp:197
class IndexingTreeCleanupTask : public RefProcTask {
  volatile uint _claim_counter;
public:
  IndexingTreeCleanupTask(ReferenceProcessor& rp)
    : RefProcTask(rp, nullptr), _claim_counter(0) {}

  void rp_work(uint, BoolObjectClosure* is_alive, OopClosure* keep_alive,
               EnqueueDiscoveredFieldClosure*, VoidClosure* complete_gc) override {
    // Per-tree atomic claim — every worker calls fetch_then_add on the
    // same counter.  complete_gc=nullptr inside per-tree work; we run a
    // single converging drain afterwards so idle workers join the
    // steal-loop instead of returning early and deadlocking the busy
    // worker on the shared TaskTerminator.
    IndexingTreeManager::clean_trees_par_indexed(&_claim_counter, is_alive,
                                                 keep_alive, /*complete_gc=*/nullptr);
    complete_gc->do_void();
  }
};

// referenceProcessor.cpp:264 — gate
if (WeakArrayScanScope::in(WeakArrayScanScope::StrongMark) ||
    WeakArrayScanScope::in(WeakArrayScanScope::YoungScan)) {
  IndexingTreeCleanupTask idx_task(*this);
  // ...processing_is_mt() branch dispatches workers; ST branch runs work(0)...
}
```

Per-tree claim:

```cpp
// indexingTreeManager.cpp:231
void IndexingTreeManager::clean_trees_par_indexed(volatile uint* counter, ...) {
  uint n = (uint) _tree_slots->length();
  while (true) {
    uint idx = Atomic::fetch_then_add(counter, 1u);
    if (idx >= n) break;
    clean_one_slot(_tree_slots->at((int) idx), is_alive, keep_alive, complete_gc);
  }
}
```

Granularity = single tree, so cleanup parallelizes whenever the registry
holds ≥ 2 trees. OopStorage's per-block claim would be too coarse for
small registries.

### Per-collector gates

Manual slot loops bypass klass dispatch. Each one needs a gate.

```cpp
// src/hotspot/share/gc/parallel/psPromotionManager.inline.hpp:285
// Don't chunk weak arrays — chunk worker iterates raw offsets.
if (a->klass()->is_weak_objArray_klass()) push_contents(a);
else                                       /* normal chunking */;

// psPromotionManager.cpp:308 — defense-in-depth for stolen tasks.
if (a->klass()->is_weak_objArray_klass()) return;

// psCompactionManager.inline.hpp:160 — Parallel full GC follow_array.
if (klass->is_weak_objArray_klass() &&
    WeakArrayScanScope::in(WeakArrayScanScope::StrongMark)) return;
```

### Per-collector status

| Collector  | Young suppression  | Full / mark cleanup | Notes |
|---|---|---|---|
| Serial     | ✓                   | ✓                    | Stable. |
| Parallel   | ✓                   | ✓                    | Stable; chunking gates required. |
| G1         | ✓                   | ✓ at remark          | Conservative keep_alive in young∩mark. |
| Shenandoah | stub                | stub                 | `clean_all_trees_marked` defined; hook stubbed (~5–10 LOC + days of debug). |
| ZGC        | stub                | stub                 | Same. |

### Closure cheat sheet

These are the three closure types `clean_tree` consumes. The collector
supplies them; we just call them.

```cpp
// src/hotspot/share/memory/iterator.hpp
class OopClosure : public Closure {
  virtual void do_oop(oop* o)       = 0;
  virtual void do_oop(narrowOop* o) = 0;
};

class OopIterateClosure : public OopClosure {
  enum ReferenceIterationMode {
    DO_DISCOVERY,                // also discover j.l.r.Reference fields
    DO_DISCOVERED_AND_DISCOVERY,
    DO_FIELDS,
    DO_FIELDS_EXCEPT_REFERENT
  };
  virtual ReferenceIterationMode reference_iteration_mode() { return DO_DISCOVERY; }
  // + do_metadata / do_klass / do_cld / do_method / do_nmethod
};

class BoolObjectClosure : public Closure {
  virtual bool do_object_b(oop obj) = 0;   // "is this oop live?"
};

class VoidClosure : public StackObj {
  virtual void do_void() = 0;              // "drain pending work"
};
```

#### `BoolObjectClosure* is_alive`

Pass an oop, get back "is it alive *outside* the indexing tree?".
Implementation depends on collector phase:

| Phase                  | What `do_object_b` returns true for |
|---|---|
| Young GC               | already-forwarded oops (copied to to-space) |
| Full / strong mark     | mark-bit-set oops |
| Shenandoah / ZGC mark  | mark-bit-set oops at end of mark cycle |

Use: Phase 1 calls `is_alive->do_object_b(key)` for every key in every
entry. False → unlink the entry.

A `nullptr` key counts as alive (`key_is_alive` early-returns true) —
empty key slots in partial-arity entries shouldn't keep the entry alive
or kill it.

#### `OopClosure* keep_alive`

Pass the *address* of an oop slot. The closure follows the oop, marks
it live, and may copy/forward in place (depends on collector). After
return the slot may hold the new address.

| Phase           | What `do_oop` does |
|---|---|
| Young GC        | Copy the oop to to-space, update the slot to the new address |
| Full / mark     | Set the mark bit, push onto the worker's mark stack |
| G1 evac         | Same as young, plus barrier bookkeeping |

Use: Phase 2 calls `keep_alive->do_oop(slot_addr)` on every surviving
bucket-head slot. Because `IndexingTreeEntry`'s normal oop_map covers
`keys`, `value`, and `next`, marking the head transitively marks the
whole live chain.

For full GC we also keep the table field alive — the bucket array
itself isn't reachable from anything else once we suppress its strong
edge:

```cpp
keep_alive->do_oop(tree->field_addr<T>(java_lang_rv_IndexingTree::table_offset()));
```

We pass the slot *address*, not the value, because moving collectors
patch the slot in place.

#### `VoidClosure* complete_gc`

Drain whatever pending work the closure pair has accumulated — usually
the worker's mark-stack or copy-queue.

Use: every 256 keep_alive calls, call `complete_gc->do_void()` so the
worker's per-thread stack doesn't overflow during a long Phase 2 over a
multi-million-entry tree. Also called once at the end of Phase 2.

Inside parallel cleanup we pass `nullptr` for `complete_gc` per tree
and run one `complete_gc->do_void()` after the whole parallel section —
otherwise idle workers (those that lost the claim race) would return
early instead of joining the shared TaskTerminator's steal loop, and
the busy worker would deadlock waiting for steal partners.

#### How the three fit together

```
collector ──┐
            │  (is_alive, keep_alive, complete_gc)
            ▼
  ┌────────────────────────────────────────┐
  │ IndexingTreeManager::clean_tree        │
  │                                        │
  │  Phase 1 (clean_bucket_range)          │
  │   └─ is_alive->do_object_b(key) ───────┼── "is this reachable elsewhere?"
  │      └─ false → unlink entry           │
  │                                        │
  │  Phase 2 (per surviving bucket head)   │
  │   └─ keep_alive->do_oop(slot) ─────────┼── mark/copy + transitive walk
  │   └─ every 256 calls:                  │
  │      complete_gc->do_void() ───────────┼── flush mark stack
  │                                        │
  └────────────────────────────────────────┘
```

The closures are collector-supplied; the cleanup is collector-agnostic.
That's why the same `clean_tree` body works for Serial, Parallel, G1 —
each collector wires its own copy/mark machinery into the three
closures and hands them in.
