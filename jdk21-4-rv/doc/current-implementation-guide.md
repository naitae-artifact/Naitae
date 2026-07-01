# Current JDK 21 RV IndexingTree Implementation Guide

This document is the "start here" map for the current
`jdk21-rv-young-gc-fix` implementation. It explains what was added to
OpenJDK 21, why each piece exists, and how the pieces cooperate to give
RV-Monitor indexing trees weak-key behavior without using
`WeakReference` or `ReferenceQueue`.

The short version: Java monitoring code uses `java.lang.rv.IndexingTree`
as an identity-keyed hash table. The VM treats parts of that table as a
weak reachability structure during selected GC phases. When GC knows
which keys are alive, `IndexingTreeManager` removes entries whose keys
are dead and keeps the surviving entries alive.

## 1. The Problem Being Solved

Traditional RV-Monitor indexing trees keep parameter objects through
weak references:

```text
parameter object -> WeakReference -> map entry -> monitor
```

That avoids memory leaks, but it creates costs:

- one or more `WeakReference` objects per parameter object or mapping,
- `ReferenceQueue` synchronization or polling,
- extra GC work to discover, process, clear, and enqueue weak refs,
- lots of Java-level cleanup work in hot monitoring paths.

This implementation replaces that with:

```text
parameter object -> ordinary object reference inside IndexingTreeEntry
GC phase      -> temporarily treats those references as weak
cleanup hook  -> removes entries whose keys are unreachable elsewhere
```

The important idea is that the VM already knows object liveness. The
monitoring runtime should not have to rediscover it through Java weak
references.

## 2. High-Level Architecture

```text
Generated RV code
  |
  | get1/get2/get3/getOrCreate*
  v
java.lang.rv.IndexingTree
  |
  | table field
  v
IndexingTreeEntry[] bucket array
  |
  | bucket chains
  v
IndexingTreeEntry -> keys[] + value monitor + next

HotSpot additions:

InstanceIndexingTreeKlass
  Controls whether the IndexingTree.table field is traced.

WeakObjArrayKlass
  Controls whether bucket-array slots are traced.

WeakArrayScanScope
  Global phase bitmask saying "we are in a GC phase where RV table
  references should be weak".

IndexingTreeManager
  Registry and cleanup algorithm. It scans all trees, removes entries
  with dead keys, and keeps surviving entries alive.
```

The design uses two levels of suppression:

1. `InstanceIndexingTreeKlass` can suppress or trace the `table` field.
2. `WeakObjArrayKlass` can suppress or trace the table's bucket slots.

That lets the VM keep the table object itself valid when needed, while
not letting bucket entries keep parameter objects alive.

## 3. Java API Added to `java.base`

New package:

```text
src/java.base/share/classes/java/lang/rv/
```

### `IndexingTree`

File:

```text
src/java.base/share/classes/java/lang/rv/IndexingTree.java
```

This is the Java object used by generated monitoring code. It is a
flattened identity-key hash table.

Main fields:

```java
protected int size;
protected final int id;
protected int upThreshold;
protected int downThreshold;
protected IndexingTreeEntry[] table;
protected int capacity;
```

Main operations:

```java
get(Object... keys)
get1(Object key1)
get2(Object key1, Object key2)
get3(Object key1, Object key2, Object key3)

put(Object value, Object... keys)

getOrCreate(RuntimeMonitorFactory factory, Object... keys)
getOrCreate1(RuntimeMonitorFactory factory, Object key1)
getOrCreate2(RuntimeMonitorFactory factory, Object key1, Object key2)
getOrCreate3(RuntimeMonitorFactory factory, Object key1, Object key2, Object key3)
```

Observations:

- The implementation is identity-based: keys are compared with `==`.
- Hashing uses `System.identityHashCode`.
- The arity-specialized `get1/get2/get3` and `getOrCreate1/2/3` avoid
  varargs at common lookup sites.
- Public methods are currently `synchronized`.
- The constructor calls a native `registerTree()` so the VM can find all
  trees during GC.
- Table allocation goes through native `allocateTable(int)`, not plain
  `new IndexingTreeEntry[capacity]`, because the VM must allocate the
  array with a special array klass.

### `IndexingTreeEntry`

File:

```text
src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java
```

This is the bucket-chain node:

```java
protected final int hashCode;
protected final Object[] keys;
protected Object value;
protected IndexingTreeEntry next;
```

Meaning:

- `hashCode`: aggregate identity hash for the key tuple.
- `keys`: parameter-object tuple.
- `value`: monitor, monitor set, tuple, or intermediate generated object.
- `next`: next entry in the hash bucket chain.

The `final` fields are intentional. They make publication of
`hashCode` and `keys` more robust under JIT-compiled code and concurrent
access.

### `RuntimeMonitorFactory`

File:

```text
src/java.base/share/classes/java/lang/rv/RuntimeMonitorFactory.java
```

This is a small callback object:

```java
abstract public Object createMonitor();
```

`getOrCreate*` uses it to lazily create a monitor only when a lookup
misses.

### Module Export

`java.base` exports `java.lang.rv` so woven/generated monitor code can
access these classes.

## 4. Native Bridge

Files:

```text
src/java.base/share/native/libjava/IndexingTree.c
src/hotspot/share/include/jvm.h
src/hotspot/share/prims/jvm.cpp
make/data/hotspot-symbols/symbols-unix
```

Two JVM entry points were added:

```cpp
JVM_IndexingTreeRegister(JNIEnv* env, jobject tree)
JVM_IndexingTreeAllocTable(JNIEnv* env, jclass cls, jint capacity)
```

### `JVM_IndexingTreeRegister`

Called from the `IndexingTree` constructor.

It resolves the Java `IndexingTree` object and stores it in the
VM-side `IndexingTreeManager` registry.

### `JVM_IndexingTreeAllocTable`

Called whenever Java needs a new bucket array.

It does several non-obvious things:

1. Pads the requested table capacity so the array aligns with GC card
   boundaries on card-table collectors.
2. Resolves `java.lang.rv.IndexingTreeEntry`.
3. Marks the `IndexingTreeEntry` class as an element type that creates
   special weak arrays.
4. Requests the `IndexingTreeEntry[]` array klass.
5. Asserts that the resulting array klass is `WeakObjArrayKlass`.
6. Allocates and returns the array.

This is how an ordinary-looking Java field:

```java
IndexingTreeEntry[] table;
```

actually becomes a VM-special array whose element traversal can be
suppressed during GC.

## 5. New HotSpot Klass Types

Two new HotSpot klass types were added.

### `InstanceIndexingTreeKlass`

Files:

```text
src/hotspot/share/oops/instanceIndexingTreeKlass.hpp
src/hotspot/share/oops/instanceIndexingTreeKlass.cpp
src/hotspot/share/oops/instanceIndexingTreeKlass.inline.hpp
```

This is the VM representation for Java objects of class:

```text
java.lang.rv.IndexingTree
```

Normally, an `InstanceKlass` has oop maps telling GC which instance
fields are object references. `IndexingTree` has one reference field,
`table`.

This implementation removes the `table` field from normal oop maps:

```cpp
map->set_count(0);
```

Then `InstanceIndexingTreeKlass::oop_oop_iterate` manually decides when
to trace the table field.

That decision is controlled by `WeakArrayScanScope`:

- in normal phases, trace `table`;
- in weak/suppressed phases, skip `table`;
- in special young/mixed cases, trace `table` when the array itself may
  need to be copied or kept valid.

The purpose is to avoid treating the whole indexing tree as a strong
root during phases where table entries should behave like weak entries.

### `WeakObjArrayKlass`

Files:

```text
src/hotspot/share/oops/weakObjArrayKlass.hpp
src/hotspot/share/oops/weakObjArrayKlass.cpp
src/hotspot/share/oops/weakObjArrayKlass.inline.hpp
```

This is a subclass of `ObjArrayKlass`.

It is used for:

```text
java.lang.rv.IndexingTreeEntry[]
```

During selected phases, it returns before visiting array slots:

```cpp
if (weak_objarray_suppress(closure)) return;
```

That means a bucket array does not strongly trace its entries during
those phases. The cleanup algorithm later decides which bucket entries
should survive.

This is the most important JDK 21 design change compared with the
OpenJDK 7 version. Instead of relying only on the tree instance's custom
klass, the current version gives the bucket array itself special weak
iteration behavior.

## 6. Klass Plumbing

Several VM areas had to know about the new klass kinds.

Files include:

```text
src/hotspot/share/oops/klass.hpp
src/hotspot/share/oops/objArrayKlass.hpp
src/hotspot/share/oops/objArrayKlass.cpp
src/hotspot/share/oops/objArrayKlass.inline.hpp
src/hotspot/share/oops/instanceKlass.hpp
src/hotspot/share/oops/instanceKlass.cpp
src/hotspot/share/memory/iterator.inline.hpp
src/hotspot/share/cds/cppVtables.cpp
```

Changes include:

- new `KlassKind` values:
  - `InstanceIndexingTreeKlassKind`,
  - `WeakObjArrayKlassKind`;
- `is_objArray_klass()` now treats both ordinary object arrays and weak
  object arrays as object-array klasses;
- `InstanceKlass` has a `_creates_weak_arrays` flag;
- `ObjArrayKlass::allocate_objArray_klass` can allocate a
  `WeakObjArrayKlass` when requested;
- oop iteration dispatch tables register both new klasses;
- CDS/vtable support knows about `InstanceIndexingTreeKlass`.

## 7. Phase State: `WeakArrayScanScope`

Files:

```text
src/hotspot/share/gc/shared/weakArrayScanScope.hpp
src/hotspot/share/gc/shared/weakArrayScanScope.cpp
```

This is a small global phase-state mechanism. It records whether the VM
is in a phase where indexing-tree table references should be treated
specially.

Modes:

```cpp
YoungScan
StrongMark
G1Mixed
```

Who reads it:

- `InstanceIndexingTreeKlass` reads it to decide whether to trace the
  `IndexingTree.table` field.
- `WeakObjArrayKlass` reads it to decide whether to trace bucket-array
  slots.
- `IndexingTreeManager` reads it to decide whether cleanup is young-GC
  cleanup or full/strong-mark cleanup.

Who sets it:

- Serial young GC,
- Serial full GC,
- Parallel young GC,
- Parallel full GC,
- G1 young GC,
- G1 full GC,
- G1 concurrent mark.

Most uses are RAII scoped:

```cpp
WeakArrayScanScope scope(WeakArrayScanScope::YoungScan);
```

G1 concurrent marking uses explicit `enter` and `leave`, because the
phase is not contained by one stack frame.

## 8. `IndexingTreeManager`

Files:

```text
src/hotspot/share/utilities/indexingTreeManager.hpp
src/hotspot/share/utilities/indexingTreeManager.cpp
```

This is the VM-side owner of all live indexing trees.

### Registry

The manager creates a strong `OopStorage`:

```cpp
OopStorageSet::create_strong("IndexingTree", mtGC);
```

Every Java `IndexingTree` registers itself here. Strong storage is used
so the tree object itself and the storage pointer are updated correctly
across moving collectors.

### Cleanup Algorithm

At a high level:

```text
for each registered tree:
  table = tree.table
  for each bucket:
    walk linked entries
    if any key is not alive:
      unlink the entry
    else:
      leave it in the chain
  update tree.size
  keep_alive each surviving bucket head
```

The liveness predicate is not invented by this code. It is passed in
from the active collector:

```cpp
BoolObjectClosure* is_alive
```

The keep-alive operation is also passed in from the active collector:

```cpp
OopClosure* keep_alive
```

That is a good design choice: the cleanup code is generic, but actual
marking/copying remains collector-specific.

### Why Two Phases?

Phase 1 removes dead entries while the bucket chain is still readable.

Phase 2 keeps the survivors alive. After bucket heads are kept alive,
the collector's normal object traversal follows:

```text
entry -> keys array
entry -> monitor value
entry -> next
```

So surviving monitor state remains live, while dead monitor state loses
its final indexing-tree path and can be collected.

## 9. ReferenceProcessor Hook

File:

```text
src/hotspot/share/gc/shared/referenceProcessor.cpp
```

The cleanup hook is added near the end of:

```cpp
ReferenceProcessor::process_discovered_references(...)
```

When either `StrongMark` or `YoungScan` mode is active, it runs:

```cpp
IndexingTreeManager::clean_all_trees(is_alive, keep_alive, complete_gc);
```

This placement is important because:

- normal marking/copying has already established which objects are live;
- Java weak/soft/final/phantom reference processing is happening in the
  same conceptual part of the GC;
- the collector's own `is_alive` and `keep_alive` closures are available.

This makes indexing-tree cleanup act like a VM-supported weak structure.

## 10. Collector-Specific Integration

The current implementation touches several collectors. The common goal
is always the same:

1. Enter the right `WeakArrayScanScope`.
2. Let ordinary GC tracing avoid table entries during that phase.
3. Run cleanup through `ReferenceProcessor`.
4. Keep surviving entries alive using the collector's own closure.

### Serial Young GC

File:

```text
src/hotspot/share/gc/serial/defNewGeneration.cpp
```

Wraps root scanning and reference processing in:

```cpp
WeakArrayScanScope(IndexingTreeYoungGC ? YoungScan : None)
```

When enabled, table slots are suppressed during young collection, and
the reference-processing hook cleans dead entries.

### Serial Full GC

File:

```text
src/hotspot/share/gc/serial/genMarkSweep.cpp
```

Wraps mark/reference-processing work in:

```cpp
WeakArrayScanScope(StrongMark)
```

This makes full GC treat indexing-tree table entries as weak until the
cleanup pass decides which ones survive.

### Parallel Young GC

File:

```text
src/hotspot/share/gc/parallel/psScavenge.cpp
```

Uses `YoungScan` around scavenge and reference processing.

Extra support exists because Parallel GC has array chunking paths that
can bypass normal klass dispatch.

Files:

```text
src/hotspot/share/gc/parallel/psPromotionManager.inline.hpp
src/hotspot/share/gc/parallel/psPromotionManager.cpp
```

Those changes prevent `WeakObjArrayKlass` bucket arrays from being
processed through raw array chunk tasks during young GC. Otherwise the
code would directly scan array slots and defeat the weak-array
suppression.

### Parallel Full GC

Files:

```text
src/hotspot/share/gc/parallel/psParallelCompact.cpp
src/hotspot/share/gc/parallel/psCompactionManager.inline.hpp
```

Parallel full GC has another raw object-array traversal path. The guard
in `ParCompactionManager::follow_array` suppresses tracing of
`WeakObjArrayKlass` slots during `StrongMark`.

### G1 Young GC

File:

```text
src/hotspot/share/gc/g1/g1YoungCollector.cpp
```

Uses `YoungScan` during evacuation. If G1 is in mixed phase, it also
sets `G1Mixed`.

`G1Mixed` matters because mixed collections can evacuate old regions.
In that case, the tree's table field may need to be traced so the table
object remains valid, while the table slots are still suppressed by
`WeakObjArrayKlass`.

### G1 Full GC

File:

```text
src/hotspot/share/gc/g1/g1FullCollector.cpp
```

Uses `StrongMark` during full-GC marking and reference processing.

### G1 Concurrent Mark

File:

```text
src/hotspot/share/gc/g1/g1ConcurrentMark.cpp
```

Uses explicit:

```cpp
WeakArrayScanScope::enter(StrongMark)
WeakArrayScanScope::leave(StrongMark)
```

This exists because G1 concurrent mark is not a simple single-stack-frame
scope.

Design caveat: G1's SATB barrier can retain old slot values that were
stored before or during concurrent marking. That means concurrent-mark
cleanup may be less effective than young/full cleanup for some tables.
This is expected behavior for SATB collectors, not a correctness bug.

### Shenandoah and ZGC

Files contain TODOs:

```text
src/hotspot/share/gc/shenandoah/shenandoahConcurrentGC.cpp
src/hotspot/share/gc/z/zGeneration.cpp
```

The current code acknowledges that proper integration for these
concurrent/load-barrier collectors needs a separate design pass. The
core implementation is much more mature for Serial, Parallel, and G1.

## 11. Runtime Flags

File:

```text
src/hotspot/share/gc/shared/gc_globals.hpp
```

Added flags:

```cpp
IndexingTreeYoungGC
IndexingTreeClearCards
```

`IndexingTreeYoungGC` controls whether young collections attempt
indexing-tree cleanup.

`IndexingTreeClearCards` appears as a flag for card-table handling, but
in the current codebase it is not the main mechanism. The current design
mostly relies on `WeakObjArrayKlass`, `WeakArrayScanScope`, and
ReferenceProcessor cleanup.

## 12. JavaClasses and VM Symbol Wiring

Files:

```text
src/hotspot/share/classfile/javaClasses.hpp
src/hotspot/share/classfile/javaClasses.cpp
src/hotspot/share/classfile/javaClasses.inline.hpp
src/hotspot/share/classfile/vmSymbols.hpp
src/hotspot/share/classfile/vmClassMacros.hpp
```

These changes let C++ code find and access fields in:

```text
java.lang.rv.IndexingTree
java.lang.rv.IndexingTreeEntry
java.lang.rv.RuntimeMonitorFactory
```

Examples:

```cpp
java_lang_rv_IndexingTree::table(oop tree)
java_lang_rv_IndexingTree::size_value(oop tree)
java_lang_rv_IndexingTreeEntry::keys(oop entry)
java_lang_rv_IndexingTreeEntry::next(oop entry)
```

This is standard HotSpot style for VM-known Java classes.

## 13. What Was Removed From the Earlier JDK 21 Experiment

Compared with the sibling `jdk21-rv` tree, this branch removes an
earlier native/JIT-intrinsic table experiment.

Removed or backed out pieces include:

- `IndexingTreeRuntime` C++ runtime helpers,
- C1 intrinsics for native slot access,
- C2 intrinsics for native lookup/put paths,
- `vmIntrinsics` entries such as `_indexingTreeLookupNative`,
  `_indexingTreePutNative`, and slot get/put intrinsics.

The current branch is therefore less of a "native table with JIT
intrinsics" design and more of a "Java table with VM-managed weak GC
semantics" design.

This is an important distinction for the paper/design story.

## 14. End-to-End Flow

### Normal Lookup/Create

```text
RV event fires
  |
  v
generated aspect calls tree.getOrCreate2(factory, key1, key2)
  |
  v
IndexingTree computes identity hash
  |
  v
walks bucket chain in IndexingTreeEntry[]
  |
  +-- hit  -> return existing monitor
  |
  +-- miss -> factory.createMonitor()
             create IndexingTreeEntry
             insert into bucket chain
             maybe resize
```

### GC Cleanup

```text
GC enters YoungScan or StrongMark
  |
  v
InstanceIndexingTreeKlass / WeakObjArrayKlass suppress selected tracing
  |
  v
normal GC discovers actual liveness outside the indexing tree
  |
  v
ReferenceProcessor runs
  |
  v
IndexingTreeManager scans registered trees
  |
  v
for each entry:
  if any key is dead outside the tree:
    unlink entry
  else:
    keep surviving bucket chain alive
  |
  v
dead monitors become unreachable and are reclaimed normally
```

## 15. Why This Design Is Reasonable

The design is good because it keeps responsibilities separated:

- Java code remains a normal hash table API for generated monitoring
  code.
- HotSpot klass code controls reachability semantics.
- Collector-specific code supplies the correct liveness and keep-alive
  closures.
- Cleanup logic is centralized in `IndexingTreeManager`.

The key research contribution is not just "a faster map". It is the
idea that a VM can expose weak-key indexing semantics specialized for
parametric monitoring, avoiding general-purpose weak-reference overhead.

## 16. Main Design Costs

The current design also has real complexity:

- it depends on GC phase timing;
- it modifies HotSpot klass dispatch;
- it needs collector-specific gates for raw array traversal paths;
- concurrent collectors need separate reasoning;
- `IndexingTree` is still Java-object-heavy (`Entry` plus `Object[]`
  per tuple);
- all public Java methods are synchronized;
- cleanup currently runs through a single cleanup task path.

These are not fatal, but they are the places where future performance
and design work should focus.

## 17. Performance Improvement Ideas To Track Next

Most promising next changes:

1. Add `put1`, `put2`, and `put3` so generated code never needs varargs
   on hot paths.
2. Replace `Object[] keys` with arity-specialized entry layouts.
3. Reduce or remove duplicate synchronization if generated monitor code
   already serializes events.
4. Change `% capacity` to power-of-two mask indexing with hash spreading.
5. Make young-GC cleanup adaptive based on dead/live yield from the last
   cleanup.
6. Parallelize cleanup across trees or bucket ranges for large
   multi-property workloads.
7. Reconsider shrink policy; shrinking during active monitoring may cost
   more runtime than it saves in memory.
8. Consider generated property-specific tree classes, because RV-Monitor
   already generates code and can exploit fixed arity/value type.

## 18. File Index By Concept

Java API:

```text
src/java.base/share/classes/java/lang/rv/IndexingTree.java
src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java
src/java.base/share/classes/java/lang/rv/RuntimeMonitorFactory.java
```

Native bridge:

```text
src/java.base/share/native/libjava/IndexingTree.c
src/hotspot/share/include/jvm.h
src/hotspot/share/prims/jvm.cpp
make/data/hotspot-symbols/symbols-unix
```

Custom klasses:

```text
src/hotspot/share/oops/instanceIndexingTreeKlass.hpp
src/hotspot/share/oops/instanceIndexingTreeKlass.cpp
src/hotspot/share/oops/instanceIndexingTreeKlass.inline.hpp
src/hotspot/share/oops/weakObjArrayKlass.hpp
src/hotspot/share/oops/weakObjArrayKlass.cpp
src/hotspot/share/oops/weakObjArrayKlass.inline.hpp
```

Klass/object-array plumbing:

```text
src/hotspot/share/oops/klass.hpp
src/hotspot/share/oops/instanceKlass.hpp
src/hotspot/share/oops/instanceKlass.cpp
src/hotspot/share/oops/objArrayKlass.hpp
src/hotspot/share/oops/objArrayKlass.cpp
src/hotspot/share/oops/objArrayKlass.inline.hpp
src/hotspot/share/memory/iterator.inline.hpp
src/hotspot/share/cds/cppVtables.cpp
```

Phase state:

```text
src/hotspot/share/gc/shared/weakArrayScanScope.hpp
src/hotspot/share/gc/shared/weakArrayScanScope.cpp
```

Cleanup:

```text
src/hotspot/share/utilities/indexingTreeManager.hpp
src/hotspot/share/utilities/indexingTreeManager.cpp
src/hotspot/share/gc/shared/referenceProcessor.cpp
```

Collector hooks:

```text
src/hotspot/share/gc/serial/defNewGeneration.cpp
src/hotspot/share/gc/serial/genMarkSweep.cpp
src/hotspot/share/gc/parallel/psScavenge.cpp
src/hotspot/share/gc/parallel/psParallelCompact.cpp
src/hotspot/share/gc/parallel/psPromotionManager.cpp
src/hotspot/share/gc/parallel/psPromotionManager.inline.hpp
src/hotspot/share/gc/parallel/psCompactionManager.inline.hpp
src/hotspot/share/gc/g1/g1YoungCollector.cpp
src/hotspot/share/gc/g1/g1FullCollector.cpp
src/hotspot/share/gc/g1/g1ConcurrentMark.cpp
src/hotspot/share/gc/shenandoah/shenandoahConcurrentGC.cpp
src/hotspot/share/gc/z/zGeneration.cpp
```

Runtime flags:

```text
src/hotspot/share/gc/shared/gc_globals.hpp
```

VM-known Java class accessors:

```text
src/hotspot/share/classfile/javaClasses.hpp
src/hotspot/share/classfile/javaClasses.cpp
src/hotspot/share/classfile/javaClasses.inline.hpp
src/hotspot/share/classfile/vmSymbols.hpp
src/hotspot/share/classfile/vmClassMacros.hpp
```

## 19. How To Read The Code

Recommended reading order:

1. `IndexingTree.java`
2. `IndexingTreeEntry.java`
3. `jvm.cpp`, only the `JVM_IndexingTree*` functions
4. `weakArrayScanScope.hpp`
5. `instanceIndexingTreeKlass.inline.hpp`
6. `weakObjArrayKlass.inline.hpp`
7. `indexingTreeManager.cpp`
8. `referenceProcessor.cpp`
9. one collector at a time, starting with G1 young or Parallel young

This order avoids starting in the collector code, where the small hooks
look mysterious until the table/tracing model is clear.

