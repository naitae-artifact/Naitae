# RV-JDK Modifications to OpenJDK 21

Canonical reference for all changes this fork makes to upstream
OpenJDK 21.0.10-ga (tag `jdk-21.0.10-ga`, commit `6f426cb88`).

Purpose: in-JVM support for parametric runtime monitoring. The JVM
provides an identity-keyed hash table (`java.lang.rv.IndexingTree`)
whose entries are reclaimed automatically during garbage collection,
replacing the `WeakReference` + `ReferenceQueue` mechanism used by
RV-Monitor and similar frameworks. Based on *A Virtual Machine Support
for Parametric Monitoring* (PLDI 2016).

88 files changed, ~15 kLoC added, ~90 lines removed.

## Contents

1. [Architecture](#architecture)
2. [Java API](#java-api)
3. [JNI bridge](#jni-bridge)
4. [HotSpot klass hierarchy](#hotspot-klass-hierarchy)
5. [Phase-state scope](#phase-state-scope)
6. [IndexingTreeManager](#indexingtreemanager)
7. [GC integration — per collector](#gc-integration--per-collector)
8. [Classfile and symbol wiring](#classfile-and-symbol-wiring)
9. [Misc VM plumbing](#misc-vm-plumbing)
10. [Runtime flags](#runtime-flags)
11. [Tests](#tests)
12. [Benchmarks and harness](#benchmarks-and-harness)
13. [Unfinished: Shenandoah, ZGC](#unfinished-shenandoah-zgc)

---

## Architecture

```
Java mutator                 HotSpot runtime                GC
────────────                 ───────────────                ──
IndexingTree              ──▶ InstanceIndexingTreeKlass ──▶ wrapper iterate:
  .table: IndexingTreeEntry[]                                defers `table` in
                                                             suppressed phases
        │
        └────────────▶       WeakObjArrayKlass          ──▶ array iterate:
                               (extends ObjArrayKlass)       defers all slots
                                                             in suppressed
                                                             phases

                             WeakArrayScanScope          ◀── phase state:
                                                             YoungScan |
                                                             StrongMark |
                                                             G1Mixed

                             IndexingTreeManager         ◀── cleanup task
                                                             (walks registry,
                                                              prunes dead,
                                                              keeps live alive)
```

**Two custom klasses** decouple GC tracing from the ordinary
strong-reference semantics of their oops:

- [`InstanceIndexingTreeKlass`](../src/hotspot/share/oops/instanceIndexingTreeKlass.hpp)
  for the tree wrapper (`IndexingTree` instance). Removes the `table`
  field from the parent `InstanceKlass` oop map so default traversal
  never sees it; re-adds it in the override `oop_oop_iterate` unless
  an active [`WeakArrayScanScope`](../src/hotspot/share/gc/shared/weakArrayScanScope.hpp)
  mode says to skip.
- [`WeakObjArrayKlass`](../src/hotspot/share/oops/weakObjArrayKlass.hpp)
  for the bucket array (`IndexingTreeEntry[]`). Inherits from
  `ObjArrayKlass`; overrides `oop_oop_iterate`, `_bounded`, `_reverse`
  to skip slot visitation in suppressed phases. Allocation is routed
  by `InstanceKlass::_creates_weak_arrays` on the element type.

**Phase state** ([`WeakArrayScanScope`](../src/hotspot/share/gc/shared/weakArrayScanScope.hpp))
is a thread-global bitmask {`YoungScan`, `StrongMark`, `G1Mixed`},
manipulated RAII-style by each collector's young/full/concurrent
entry points. Both klasses read the same state.

**Cleanup** ([`IndexingTreeManager`](../src/hotspot/share/utilities/indexingTreeManager.hpp))
maintains a strong `OopStorage` of live trees. At end of
`ReferenceProcessor::process_discovered_references`, when a scope is
active, the manager walks every registered tree: for each entry with
at least one key that is_alive returns false, unlink it; then
keep_alive the surviving chain heads so GC copies/marks the rest.

---

## Java API

All new sources live in `java.base/share/classes/java/lang/rv/`.
Exported to all modules via `module-info.java`.

### [`IndexingTree.java`](../src/java.base/share/classes/java/lang/rv/IndexingTree.java)

Identity-keyed hash table. 381 lines. Public surface:

```java
package java.lang.rv;

public final class IndexingTree {
    public IndexingTree();                                  // default capacity
    public synchronized Object get(Object... keys);
    public synchronized Object get1(Object key1);           // fast-path for 1 key
    public synchronized Object get2(Object key1, Object key2);
    public synchronized Object get3(Object key1, Object key2, Object key3);
    public synchronized void put(Object value, Object... keys);
    public synchronized Object getOrCreate(RuntimeMonitorFactory f, Object... keys);
    public synchronized Object getOrCreate1(RuntimeMonitorFactory f, Object key1);
    public synchronized Object getOrCreate2(...);
    public synchronized Object getOrCreate3(...);
}
```

All public methods `synchronized`. Serializes concurrent access;
avoids an unsafe-publication race observed once GC cleanup started
actually removing entries under C2-compiled lookups.

Internals:
- `table: IndexingTreeEntry[]` — bucket array; **this is the
  `WeakObjArrayKlass` instance**.
- `size, capacity, upThreshold, downThreshold` — standard hash-table
  accounting.
- `id` — unique tree ID assigned at construction.
- `registerNatives()` + `allocateTable(int)` — JNI downcalls
  (see [JNI bridge](#jni-bridge)).

Resize semantics: standard grow-on-load-factor + shrink-on-low-density.
Resize-down is gated by `checkDownCapacity()` so GC cleanup shrinks
tables after mass entry death.

### [`IndexingTreeEntry.java`](../src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java)

35 lines. Chain node with `final int hashCode`, `final Object[] keys`,
`Object value`, `IndexingTreeEntry next`. The `final` on `hashCode`
and `keys` is load-bearing: without JMM freeze semantics, C2-compiled
concurrent lookups could observe a partial `keys` pointer during a
put that races with cleanup. Observed to crash on G1+pmd before the
fields were marked final.

### [`RuntimeMonitorFactory.java`](../src/java.base/share/classes/java/lang/rv/RuntimeMonitorFactory.java)

18 lines. Abstract class with a single `createMonitor()` callback.
Used by `getOrCreate` variants to lazily build a monitor when a
parameter-instance lookup misses.

### `module-info.java`

One-line addition: `exports java.lang.rv;` so instrumentation code
outside `java.base` can reach the API.

---

## JNI bridge

### [`libjava/IndexingTree.c`](../src/java.base/share/native/libjava/IndexingTree.c)

22 lines. Registers two Java native methods:

| Java | HotSpot entry |
|---|---|
| `IndexingTree.registerTree()` | `JVM_IndexingTreeRegister` |
| `IndexingTree.allocateTable(int)` | `JVM_IndexingTreeAllocTable` |

### [`include/jvm.h`](../src/hotspot/share/include/jvm.h)

Adds the two JVM entry declarations.

### [`prims/jvm.cpp`](../src/hotspot/share/prims/jvm.cpp)

- `JVM_IndexingTreeRegister(env, cls)` — registers `this` with
  `IndexingTreeManager::add_tree()`.
- `JVM_IndexingTreeAllocTable(env, cls, capacity)`:
  1. Pads capacity to the nearest card boundary so the bucket array
     doesn't share cards with unrelated objects (card-table collectors
     only; ZGC/Shenandoah don't need this).
  2. Resolves `java.lang.rv.IndexingTreeEntry`'s InstanceKlass.
  3. Sets `_creates_weak_arrays = true` on that InstanceKlass.
  4. Resolves the 1-dim array klass (first call instantiates it;
     because of step 3, it is a `WeakObjArrayKlass`).
  5. Asserts the klass is weak-objArray.
  6. Allocates the array of `padded_capacity` slots and returns.

---

## HotSpot klass hierarchy

### [`Klass::KlassKind`](../src/hotspot/share/oops/klass.hpp)

Two new enum values in the dispatch-driving `KlassKind`:

```cpp
enum KlassKind {
    InstanceKlassKind,
    InstanceRefKlassKind,
    InstanceMirrorKlassKind,
    InstanceClassLoaderKlassKind,
    InstanceStackChunkKlassKind,
    InstanceIndexingTreeKlassKind,    // NEW
    TypeArrayKlassKind,
    ObjArrayKlassKind,
    WeakObjArrayKlassKind,            // NEW
    UnknownKlassKind
};
static const uint KLASS_KIND_COUNT = WeakObjArrayKlassKind + 1;
```

Range predicates updated:

```cpp
bool is_instance_klass()          const { ... _kind <= InstanceIndexingTreeKlassKind ...; }
bool is_array_klass()             const { ... _kind >= TypeArrayKlassKind ...; }
bool is_objArray_klass()          const { return _kind == ObjArrayKlassKind ||
                                                 _kind == WeakObjArrayKlassKind; }
bool is_indexingTree_instance_klass() const { return _kind == InstanceIndexingTreeKlassKind; }
bool is_weak_objArray_klass()         const { return _kind == WeakObjArrayKlassKind; }
```

Both new klasses are registered in the three iterator dispatch tables
in [`memory/iterator.inline.hpp`](../src/hotspot/share/memory/iterator.inline.hpp)
(`OopOopIterateDispatch`, `OopOopIterateBoundedDispatch`,
`OopOopIterateBackwardsDispatch`).

### [`InstanceIndexingTreeKlass`](../src/hotspot/share/oops/instanceIndexingTreeKlass.hpp)

Specialized `InstanceKlass` for `java.lang.rv.IndexingTree`.

**Why a custom klass at all:** `IndexingTree`'s `table` field is the
only oop field on the wrapper and must not act as a strong-reference
root during GC phases where we want weak semantics for the chain.

**Mechanism:**
1. At classload, `update_nonstatic_oop_maps()` zeroes the count on the
   sole oop-map block so `InstanceKlass::oop_oop_iterate` — which
   parent code inherits — sees no oop fields.
2. The override `oop_oop_iterate` calls the parent implementation
   (no-op since oop map is empty), then either skips or visits the
   `table` field based on `should_skip_table()`.
3. `should_skip_table()` consults `WeakArrayScanScope` and the
   location of the table array (see below).

**`should_skip_table()` policy** ([instanceIndexingTreeKlass.inline.hpp](../src/hotspot/share/oops/instanceIndexingTreeKlass.inline.hpp)):

| Scope active | Closure mode | Decision |
|---|---|---|
| `YoungScan` | any | skip (default) |
| `YoungScan` + `StrongMark` | any | trace (G1 concurrent mark over young) |
| `YoungScan` + `G1Mixed` | any | trace (bucket array may move in old-gen evacuation) |
| `YoungScan`, table in young gen | any | trace (so scavenger copies it) |
| `StrongMark` | `DO_DISCOVERY` | skip |
| `StrongMark` | not `DO_DISCOVERY` | trace (address-adjustment paths) |
| none | any | trace |

### [`WeakObjArrayKlass`](../src/hotspot/share/oops/weakObjArrayKlass.hpp)

Specialized `ObjArrayKlass` for bucket arrays. ~130 lines across
.hpp/.cpp/.inline.hpp.

Inherits from `ObjArrayKlass` using a new protected constructor
overload that accepts a `KlassKind`. Adds no fields.

**Override suppression predicate:**

```cpp
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
```

`oop_oop_iterate<T>` / `oop_oop_iterate_bounded<T>` / `oop_oop_iterate_reverse<T>`
each do metadata handling, then return early if the predicate says so,
otherwise delegate to `ObjArrayKlass::oop_oop_iterate_elements<T>`
(now `protected` instead of `private` to permit the subclass call).

### Changes to [`ObjArrayKlass`](../src/hotspot/share/oops/objArrayKlass.hpp)

- New protected ctor overload accepting `KlassKind`. Primary ctor
  delegates with own `Kind`.
- `oop_oop_iterate_elements_bounded<T>` moved from `private` to
  `protected` for subclass access.
- `allocate_objArray_klass` gains a `bool weak` parameter; existing
  callers use a thin inline overload that passes `false`. When `true`,
  the factory placement-news a `WeakObjArrayKlass` instead of
  `ObjArrayKlass`.

### Changes to [`InstanceKlass`](../src/hotspot/share/oops/instanceKlass.hpp)

- New field `bool _creates_weak_arrays` (1 byte per InstanceKlass,
  zeroed by the ctor initializer list). When true, the cached 1-dim
  array klass is a `WeakObjArrayKlass`.
- Accessors `creates_weak_arrays()` / `set_creates_weak_arrays(bool)`.
- `InstanceKlass::array_klass(int)` — the allocation site in
  `instanceKlass.cpp` — passes `_creates_weak_arrays` to the factory.

---

## Phase-state scope

[`gc/shared/weakArrayScanScope.hpp`](../src/hotspot/share/gc/shared/weakArrayScanScope.hpp)
and `.cpp` — ~80 lines total.

```cpp
class WeakArrayScanScope : public StackObj {
 public:
    enum Mode : uint8_t {
        None       = 0,
        YoungScan  = 1 << 0,  // young-GC scavenge + card scan
        StrongMark = 1 << 1,  // full-GC DO_DISCOVERY marking
        G1Mixed    = 1 << 2,  // G1 mixed collection, old-gen evacuation active
    };

    explicit WeakArrayScanScope(uint8_t modes);  // OR bits into global
    ~WeakArrayScanScope();                       // restore previous

    static uint8_t current();
    static bool    in(Mode m);

    // Non-RAII variants for spans that cross function boundaries
    // (G1 concurrent marking: mark_from_roots → ... → weak_refs_work).
    static void enter(Mode m);
    static void leave(Mode m);
};
```

**Semantics:** a single thread-global `uint8_t _composite_mode`, OR-updated
on scope entry, restored on scope exit. Bits compose: nested scopes
that request already-set bits are no-ops; only scope-introduced bits
are cleared on exit. Plain non-volatile writes under existing safepoint
synchronization — matches the pre-refactor static-flag model.

**Call sites** (16 paired + 2 non-paired):

| File | Scope |
|---|---|
| [`gc/serial/defNewGeneration.cpp`](../src/hotspot/share/gc/serial/defNewGeneration.cpp) | `YoungScan` |
| [`gc/serial/genMarkSweep.cpp`](../src/hotspot/share/gc/serial/genMarkSweep.cpp) | `StrongMark` |
| [`gc/parallel/psScavenge.cpp`](../src/hotspot/share/gc/parallel/psScavenge.cpp) | `YoungScan` |
| [`gc/parallel/psParallelCompact.cpp`](../src/hotspot/share/gc/parallel/psParallelCompact.cpp) | `StrongMark` |
| [`gc/g1/g1YoungCollector.cpp`](../src/hotspot/share/gc/g1/g1YoungCollector.cpp) | `YoungScan` (+ `G1Mixed` when in mixed phase) |
| [`gc/g1/g1FullCollector.cpp`](../src/hotspot/share/gc/g1/g1FullCollector.cpp) | `StrongMark` |
| [`gc/g1/g1ConcurrentMark.cpp`](../src/hotspot/share/gc/g1/g1ConcurrentMark.cpp) | `StrongMark` via `enter`/`leave` (spans `mark_from_roots` → `weak_refs_work`) |

---

## IndexingTreeManager

[`utilities/indexingTreeManager.{hpp,cpp}`](../src/hotspot/share/utilities/indexingTreeManager.hpp)
— 300 lines.

**Registry:** strong `OopStorage` holds every live tree oop. Reserved
via the `strong_count + 1` increment in
[`gc/shared/oopStorageSet.hpp`](../src/hotspot/share/gc/shared/oopStorageSet.hpp).

**API:**
```cpp
class IndexingTreeManager : AllStatic {
 public:
    static void initialize();                                // called from universe_init
    static void add_tree(oop tree);                          // called from JVM_IndexingTreeRegister
    static void clean_all_trees(BoolObjectClosure* is_alive,
                                OopClosure* keep_alive,
                                VoidClosure* complete_gc);
    static void clean_all_trees_marked(BoolObjectClosure* is_alive);  // Shenandoah/ZGC
    static bool table_is_in_young(oop tree);
};
```

**Cleanup algorithm (`clean_all_trees`):**

For each registered tree:
1. Get its bucket array via `java_lang_rv_IndexingTree::table(tree)`.
2. Phase 1 — walk buckets:
   - For each chain entry, check all keys with `is_alive`.
   - If any key is dead, unlink the entry (update prev's `next` or
     the bucket head slot).
3. Phase 2 (full-GC only) — for each surviving bucket head,
   `keep_alive` the reference so GC traces the chain's `.next`, `.keys`,
   `.value` on the marking stack; drain with `complete_gc`.

**Phase 2 skipped on young GC:** liveness is the scavenger's
`is_forwarded` signal; surviving entries are copied to to-space by
normal card-scanning/root-scanning. Explicit `keep_alive` during young
GC writes into from-space copies that get discarded.

### [`gc/shared/referenceProcessor.cpp`](../src/hotspot/share/gc/shared/referenceProcessor.cpp)

Cleanup hook (~40 lines) at end of `process_discovered_references`:

```cpp
if (WeakArrayScanScope::in(WeakArrayScanScope::StrongMark) ||
    WeakArrayScanScope::in(WeakArrayScanScope::YoungScan)) {
    IndexingTreeCleanupTask idx_task(*this);
    proxy_task.prepare_run_task(idx_task, 1, RefProcThreadModel::Single, true);
    proxy_task.work(0);
}
```

Single-threaded cleanup; all tasks run on worker 0.

---

## GC integration — per collector

### Serial

- [`defNewGeneration.cpp`](../src/hotspot/share/gc/serial/defNewGeneration.cpp) — young-GC scope
- [`genMarkSweep.cpp`](../src/hotspot/share/gc/serial/genMarkSweep.cpp) — full-GC scope

Both wrap their `{ scavenge / mark } + { process_discovered_references }`
regions so the `WeakArrayScanScope` bracket includes reference
processing (where cleanup runs).

### Parallel

- [`psScavenge.cpp`](../src/hotspot/share/gc/parallel/psScavenge.cpp) — young-GC scope
- [`psParallelCompact.cpp`](../src/hotspot/share/gc/parallel/psParallelCompact.cpp) — full-GC scope
- [`psPromotionManager.cpp`](../src/hotspot/share/gc/parallel/psPromotionManager.cpp)
  (+`inline.hpp`) — **bypass-path guards**:
  - `copy_to_survivor_space`: steer bucket arrays into `push_contents`
    (klass dispatch) rather than the partial-array chunking fast path.
    Chunking iterates raw slots and bypasses klass dispatch, defeating
    our suppression.
  - `process_array_chunk_work`: defense-in-depth early return for any
    chunk task that slipped through.
- [`psCompactionManager.inline.hpp`](../src/hotspot/share/gc/parallel/psCompactionManager.inline.hpp) —
  `follow_array` bypass guard. Full-GC's `follow_array_specialized`
  also iterates slots manually; same treatment.
- [`psCardTable.cpp`](../src/hotspot/share/gc/parallel/psCardTable.cpp) —
  minor hook (shadow card table interaction).

### G1

- [`g1YoungCollector.cpp`](../src/hotspot/share/gc/g1/g1YoungCollector.cpp) —
  young-GC scope, including conditional `G1Mixed` bit when in mixed
  phase (old-gen regions are evacuation candidates → table can move).
- [`g1FullCollector.cpp`](../src/hotspot/share/gc/g1/g1FullCollector.cpp) —
  full-GC scope.
- [`g1ConcurrentMark.cpp`](../src/hotspot/share/gc/g1/g1ConcurrentMark.cpp) —
  non-RAII `enter(StrongMark)` in `mark_from_roots()`, `leave` in
  `weak_refs_work()`. Cleanup at remark runs but finds ~zero entries
  because SATB traces through captured oops, bypassing klass-level
  suppression. Known residual; subsequent young GC catches up.

### Shenandoah, ZGC

Stubs only — see [Unfinished](#unfinished-shenandoah-zgc).

---

## Classfile and symbol wiring

### [`classfile/vmSymbols.hpp`](../src/hotspot/share/classfile/vmSymbols.hpp)

Registers three class names and two signatures:
```cpp
template(java_lang_rv_IndexingTree,          "java/lang/rv/IndexingTree")
template(java_lang_rv_IndexingTreeEntry,     "java/lang/rv/IndexingTreeEntry")
template(java_lang_rv_RuntimeMonitorFactory, "java/lang/rv/RuntimeMonitorFactory")
template(indexingtreeentry_signature,        "Ljava/lang/rv/IndexingTreeEntry;")
template(indexingtreeentry_array_signature,  "[Ljava/lang/rv/IndexingTreeEntry;")
```

### [`classfile/vmClassMacros.hpp`](../src/hotspot/share/classfile/vmClassMacros.hpp)

```cpp
do_klass(IndexingTree_klass,      java_lang_rv_IndexingTree)
do_klass(IndexingTreeEntry_klass, java_lang_rv_IndexingTreeEntry)
```

### [`classfile/javaClasses.hpp`](../src/hotspot/share/classfile/javaClasses.hpp)

Adds two `AllStatic` accessor classes with field-offset caches:

- `java_lang_rv_IndexingTree` — `_size_offset`, `_id_offset`,
  `_upThreshold_offset`, `_downThreshold_offset`, `_table_offset`,
  `_capacity_offset` plus getters/setters and
  `compute_offsets()` / `serialize_offsets()` for CDS.
- `java_lang_rv_IndexingTreeEntry` — `_hashCode_offset`, `_keys_offset`,
  `_value_offset`, `_next_offset` plus accessors.

Inline implementations in
[`javaClasses.inline.hpp`](../src/hotspot/share/classfile/javaClasses.inline.hpp).
CDS offset serialization in
[`javaClasses.cpp`](../src/hotspot/share/classfile/javaClasses.cpp).

---

## Misc VM plumbing

### [`cds/cppVtables.cpp`](../src/hotspot/share/cds/cppVtables.cpp)

Adds `InstanceIndexingTreeKlass` to the `CPP_VTABLE_PATCH_TYPES_DO`
list so CDS-archived instances get the right vtable fixed up on load.
`WeakObjArrayKlass` doesn't need a separate entry — it reuses
`ObjArrayKlass`'s vtable.

### [`memory/universe.cpp`](../src/hotspot/share/memory/universe.cpp)

`universe_init()` now calls `IndexingTreeManager::initialize()` during
heap setup, which reserves the strong OopStorage slot used by the
tree registry.

### [`gc/shared/oopStorageSet.hpp`](../src/hotspot/share/gc/shared/oopStorageSet.hpp)

Bumps `strong_count` by 1 to reserve the slot.

### [`oops/objArrayOop.hpp`](../src/hotspot/share/oops/objArrayOop.hpp)

Adds `IndexingTreeManager` as a friend class — needed so the cleanup
task can use internal `objArrayOopDesc` accessors for direct bucket
mutation without going through the write barrier (the barrier
interacts badly with a raw card table).

### [`make/data/hotspot-symbols/symbols-unix`](../make/data/hotspot-symbols/symbols-unix)

Exports `JVM_IndexingTreeRegister` and `JVM_IndexingTreeAllocTable`
from `libjvm` so `libjava` can link against them.

---

## Runtime flags

Added to
[`gc/shared/gc_globals.hpp`](../src/hotspot/share/gc/shared/gc_globals.hpp):

```cpp
product(bool, IndexingTreeYoungGC, true,
        "Clean IndexingTree dead entries during young GC")

product(bool, IndexingTreeClearCards, true,
        "Clear dirty cards for IndexingTree tables before young GC "
        "(Serial/G1 only; Parallel uses shadow card table so clearing "
        "is skipped automatically).")
```

`-XX:-IndexingTreeYoungGC` disables young-GC cleanup entirely; useful
for A/B benchmarking. `IndexingTreeClearCards` controls the
card-clearing path (historical; less relevant post-refactor since
`WeakObjArrayKlass::oop_oop_iterate` handles suppression directly).

---

## Tests

### [`test/hotspot/jtreg/gc/TestIndexingTreeYoungGC.java`](../test/hotspot/jtreg/gc/TestIndexingTreeYoungGC.java)

122-line jtreg test that exercises:
- Entry creation under young GC pressure
- Unreachable-key reclamation timing (entries die at the next young GC)
- Resize correctness after mass death
- Multi-key chains surviving across GC cycles

Runs under all default collectors.

---

## Benchmarks and harness

All under `bench/`. Not essential to understand the VM changes; listed
for completeness.

- [`bench/run.sh`](../bench/run.sh) — main driver; compares stock JDK +
  WeakReference aspects ("old" mode) against RV-JDK + IndexingTree
  aspects ("new" mode) on DaCapo benchmarks.
- `bench/setup.sh`, `weave.sh`, `profile-projects.sh` — prep scripts.
- `bench/aspect-specs/` — AspectJ monitoring specs for the old/stock
  path (uses `org.apache.commons.collections.map.ReferenceIdentityMap`).
- `bench/aspect-specs-modified-hotspot/` — AspectJ specs for the new
  path (uses `java.lang.rv.IndexingTree`).
- [`bench/GcForcer.java`](../bench/GcForcer.java) — `javaagent` that
  triggers a GC between DaCapo iterations. Ensures we measure the
  steady-state cleanup behavior, not accumulation.
- [`bench/ViolationCounter.java`](../bench/ViolationCounter.java) —
  hook into RV-Monitor's violation output stream; counts violations
  for end-to-end correctness comparison between old and new modes.

---

## Unfinished: Shenandoah, ZGC

[`gc/shenandoah/shenandoahConcurrentGC.cpp`](../src/hotspot/share/gc/shenandoah/shenandoahConcurrentGC.cpp)
and [`gc/z/zGeneration.cpp`](../src/hotspot/share/gc/z/zGeneration.cpp)
each include `indexingTreeManager.hpp` and contain TODO stubs in their
mark-end paths. Cleanup is not currently invoked on either collector.

**Shenandoah:** initial attempt crashed during multi-iteration DaCapo
runs (xalan, n=10). Root cause suspected in SATB barrier interaction
or marking-context state around post-mark modification. Needs further
investigation.

**ZGC:** cleanup requires coordination with ZGC's colored-pointer /
load-barrier system. Direct field reads via raw access don't apply
the load barrier, so naive porting of the Serial/Parallel/G1 approach
doesn't work.

Both collectors currently behave as if `WeakArrayScanScope` is never
active — i.e., the tree's table is scanned normally, and no dead
entries are reclaimed. Programs run correctly but leak monitor memory
for parameter objects whose keys become unreachable.

---

## Commit history

The refactor from a single `ObjArrayKlass` boolean flag to the current
`WeakObjArrayKlass` subclass design is captured in five commits on
branch [`weak-objarray-klass`](../../commits/weak-objarray-klass):

```
3d5b8637f  oops: route IndexingTree through WeakObjArrayKlass, retire ObjArrayKlass flag
7eeea7142  oops: add WeakObjArrayKlass subclass with allocation routing
f27fa541a  gc: delete InstanceIndexingTreeKlass static phase flags
ad2588031  gc: convert IndexingTree phase-flag sites to WeakArrayScanScope
ed376db18  gc: introduce WeakArrayScanScope RAII (write-through)
```

[`doc/customKlass.md`](customKlass.md) preserves a description of the
pre-refactor (flag-based) design as historical reference.
