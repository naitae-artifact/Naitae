# IndexingTree Weak-Reference Semantics via Klass-Level Suppression

The `IndexingTree` bucket array is a plain `IndexingTreeEntry[]`. We want
entries reclaimed when their keys are unreachable *outside* the tree —
WeakReference semantics without WeakReference overhead. This needs the
GC to stop counting the bucket array as a reachability source.

## Mechanism

One bit on `ObjArrayKlass` and one branch in its iterators:

```cpp
// objArrayKlass.hpp / .inline.hpp
bool _is_indexing_tree_table;

static inline bool objarray_skip_as_indexing_tree(ObjArrayKlass* k, OopClosureType* closure) {
  if (!k->is_indexing_tree_table()) return false;
  if (InstanceIndexingTreeKlass::young_gc_active()) return true;
  if (InstanceIndexingTreeKlass::full_gc_marking() &&
      closure->reference_iteration_mode() == OopIterateClosure::DO_DISCOVERY) return true;
  return false;
}
```

The flag is set once on the `IndexingTreeEntry[]` klass in
[`JVM_IndexingTreeAllocTable`](../src/hotspot/share/prims/jvm.cpp) and
rides with the klass — any copy of the array (to-space, promoted, etc.)
keeps the suppression. When suppressed, `oop_oop_iterate*` returns
before touching any slot, so card scanning and strong marking skip the
chain entirely.

Cleanup runs in [`ReferenceProcessor::process_discovered_references`](../src/hotspot/share/gc/shared/referenceProcessor.cpp)
when `young_gc_active()` or `full_gc_marking()` is set.
[`clean_tree_impl`](../src/hotspot/share/utilities/indexingTreeManager.cpp)
does two phases per tree:

1. **Prune:** walk chains, call the collector's `is_alive` on each key,
   unlink entries with any dead key.
2. **Keep alive:** for full GC, `keep_alive` the table-array field so it
   stays marked; then `keep_alive` every surviving bucket head so drain
   follows `.next`/`.keys` and copies/marks the rest of the chain.

The phase flags are toggled by per-collector hooks (see File index).

## Per-collector notes

**Serial** and **Parallel** young GC dispatch card scanning through
`ObjArrayKlass::oop_oop_iterate{,_bounded}` (via
`PSCardTable::process_range` → `push_contents_bounded` for Parallel;
`old_gen->younger_refs_iterate` for Serial). The flag check fires,
chain stays in from-space, cleanup works.

**Parallel full GC** has its own fast path
[`follow_array_specialized`](../src/hotspot/share/gc/parallel/psCompactionManager.inline.hpp)
that iterates array slots manually and bypasses klass dispatch. We
added a matching guard in `ParCompactionManager::follow_array`.

**G1 young GC** goes through `G1ScanHRForRegionClosure::scan_memregion`
→ `oops_on_memregion_seq_iterate_careful` → `oop_iterate` → klass
dispatch → flag fires. Cleanup at reference processing works the same
way as Serial/Parallel.

**G1 concurrent mark** cleanup runs at remark but finds ~0 entries.
The SATB pre-barrier captures the old slot value on every put during
the concurrent window; the marker traces from those captured oops,
bypassing klass-level suppression entirely. Everything touched stays
marked. The following young GC catches up (observed cleaning hundreds
of thousands of entries per pause after each cycle).

**G1 full GC** works via `G1FullGCMarker::follow_object` →
`oop_iterate` → flag fires.

**ZGC / Shenandoah** TODOS!

## Java-side

- [`IndexingTreeEntry.keys` and `hashCode`](../src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java)
  are `final` (JMM freeze semantics for safe publication).
- All public methods on [`IndexingTree`](../src/java.base/share/classes/java/lang/rv/IndexingTree.java)
  are `synchronized`. Serializes concurrent put/get; eliminates the
  unsafe-publication race that became visible once cleanup started
  actually removing entries.

## Known limitations

- G1 concurrent-mark cleanup neutralized by SATB (see above).
- ZGC / Shenandoah not audited.
- Concurrent-writer stress test (`tests/IndexingTreeTest` test 5) hangs
  under high contention; not a GC crash, needs Java-side investigation.
- `IndexingTreeEntry[]` larger than the G1 humongous threshold would
  hit a humongous-object code path we haven't tested. Default 1024-slot
  tables are ~4 KB so this doesn't arise in current benchmarks.
- The `_is_indexing_tree_table` flag is set at runtime; CDS archival of
  the array klass would lose it. Not currently an issue since the class
  is runtime-loaded.

## Files


|---|---|
| Flag + suppression | [`oops/objArrayKlass.{hpp,cpp,inline.hpp}`](../src/hotspot/share/oops/objArrayKlass.hpp) |
| Phase flags + Path 1 gating | [`oops/instanceIndexingTreeKlass.inline.hpp`](../src/hotspot/share/oops/instanceIndexingTreeKlass.inline.hpp) |
| Flag set on first allocation | [`prims/jvm.cpp`](../src/hotspot/share/prims/jvm.cpp) (`JVM_IndexingTreeAllocTable`) |
| Cleanup task + registry | [`utilities/indexingTreeManager.{hpp,cpp}`](../src/hotspot/share/utilities/indexingTreeManager.cpp) |
| Cleanup hook | [`gc/shared/referenceProcessor.cpp`](../src/hotspot/share/gc/shared/referenceProcessor.cpp) |
| Serial young / full hooks | [`gc/serial/defNewGeneration.cpp`](../src/hotspot/share/gc/serial/defNewGeneration.cpp), [`genMarkSweep.cpp`](../src/hotspot/share/gc/serial/genMarkSweep.cpp) |
| Parallel young / full hooks | [`gc/parallel/psScavenge.cpp`](../src/hotspot/share/gc/parallel/psScavenge.cpp), [`psParallelCompact.cpp`](../src/hotspot/share/gc/parallel/psParallelCompact.cpp) |
| Parallel full-GC array guard | [`gc/parallel/psCompactionManager.inline.hpp`](../src/hotspot/share/gc/parallel/psCompactionManager.inline.hpp) |
| G1 young / full / concurrent-mark hooks | [`gc/g1/g1YoungCollector.cpp`](../src/hotspot/share/gc/g1/g1YoungCollector.cpp), [`g1FullCollector.cpp`](../src/hotspot/share/gc/g1/g1FullCollector.cpp), [`g1ConcurrentMark.cpp`](../src/hotspot/share/gc/g1/g1ConcurrentMark.cpp) |
| Java IndexingTree + entry | [`java.base/.../IndexingTree.java`](../src/java.base/share/classes/java/lang/rv/IndexingTree.java), [`IndexingTreeEntry.java`](../src/java.base/share/classes/java/lang/rv/IndexingTreeEntry.java) |
