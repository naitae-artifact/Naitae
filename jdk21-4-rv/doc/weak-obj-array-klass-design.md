# WeakObjArrayKlass Design

This note focuses only on `WeakObjArrayKlass`, the custom HotSpot array klass
used for `IndexingTreeEntry[]` bucket arrays.

The short version:

```text
WeakObjArrayKlass makes an ordinary Java object array weakly scanned during
specific GC phases. It does not clean the table by itself. It only prevents
normal GC traversal from following table slots too early.
```

## Problem It Solves

The Java indexing tree stores entries in a bucket array:

```text
IndexingTree
  -> table: IndexingTreeEntry[]
       table[0] -> Entry -> Entry -> ...
       table[1] -> Entry -> ...
```

Each `Entry` points to:

```text
Entry
  -> keys: Object[]
  -> value: monitor object
  -> next: Entry
```

If the bucket array is scanned like a normal `ObjArrayKlass`, then every
non-null slot keeps an entry alive. That entry keeps its `keys[]` alive. The
keys then look strongly reachable, even when the only path to them is through
the indexing tree.

That breaks weak-key semantics.

The problem edge is:

```text
table[i] -> IndexingTreeEntry
```

`WeakObjArrayKlass` exists to suppress that edge during selected GC phases.

## What It Is

`WeakObjArrayKlass` is a C++ subclass of HotSpot's `ObjArrayKlass`.

It is not a Java class. Java still sees the bucket array as:

```java
IndexingTreeEntry[]
```

But inside HotSpot, the array object's `klass()` is:

```text
WeakObjArrayKlass
```

instead of:

```text
ObjArrayKlass
```

This lets the VM keep all ordinary Java type behavior while changing how GC
iterates over the array's elements.

Relevant files:

- `src/hotspot/share/oops/weakObjArrayKlass.hpp`
- `src/hotspot/share/oops/weakObjArrayKlass.cpp`
- `src/hotspot/share/oops/weakObjArrayKlass.inline.hpp`
- `src/hotspot/share/oops/objArrayKlass.hpp`
- `src/hotspot/share/oops/objArrayKlass.cpp`
- `src/hotspot/share/prims/jvm.cpp`

## Responsibility Boundary

`WeakObjArrayKlass` does one thing:

```text
During weak scan modes, do not visit object array elements.
```

It does not:

- Decide whether a key is alive.
- Unlink dead entries.
- Keep surviving entries alive.
- Know about hash buckets or entry chains.
- Know about RV-Monitor semantics.

Those responsibilities belong to `IndexingTreeManager`.

The split is:

```text
WeakObjArrayKlass
  suppresses automatic tracing of table slots

IndexingTreeManager
  performs explicit liveness-based cleanup
```

This is important because the array klass should remain a small, reusable GC
mechanism rather than embedding indexing-tree policy.

## Why InstanceIndexingTreeKlass Is Not Enough

`InstanceIndexingTreeKlass` controls this edge:

```text
IndexingTree -> table
```

That helps when GC reaches the table through the tree object.

But GC can also encounter the table array directly:

```text
remembered set / card scan / evacuation path
  -> table array object
     -> table[i]
```

If the table array is a normal object array, direct array scanning follows every
slot and keeps entries alive. Therefore the table array itself needs custom
iteration behavior.

That is the specific design hole `WeakObjArrayKlass` fills.

## Allocation Path

The table is allocated through native VM code instead of Java bytecode.

Path:

```text
Java IndexingTree constructor
  -> native init(capacity)
     -> JVM_IndexingTreeInit
        -> alloc_indexing_table
           -> resolve java.lang.rv.IndexingTreeEntry
           -> mark IndexingTreeEntry as creating weak arrays
           -> request IndexingTreeEntry[] array klass
           -> allocate array using WeakObjArrayKlass
```

Resize uses the same native allocator:

```text
Java adjustCapacity
  -> native allocateTable(newCapacity)
     -> JVM_IndexingTreeAllocTable
        -> alloc_indexing_table
```

The key code in `jvm.cpp` is conceptually:

```cpp
Klass* entry_klass = SystemDictionary::resolve_or_fail(
    vmSymbols::java_lang_rv_IndexingTreeEntry(), true, CHECK_NULL);

InstanceKlass* ik = InstanceKlass::cast(entry_klass);
ik->set_creates_weak_arrays(true);

Klass* array_klass = entry_klass->array_klass(CHECK_NULL);
assert(array_klass->is_weak_objArray_klass(), ...);

return ObjArrayKlass::cast(array_klass)->allocate(capacity, CHECK_NULL);
```

`InstanceKlass` has a flag:

```cpp
bool _creates_weak_arrays;
```

When `IndexingTreeEntry` has this flag set, asking for its one-dimensional
array klass routes through:

```text
ObjArrayKlass::allocate_objArray_klass(..., weak = true)
  -> WeakObjArrayKlass::allocate(...)
```

Design consequence:

```text
The element type opts into weak array creation.
```

Current consumer:

```text
java.lang.rv.IndexingTreeEntry[] bucket arrays
```

## Important Timing Constraint

The weak-array flag must be set before HotSpot caches the ordinary
`IndexingTreeEntry[]` array klass.

HotSpot caches array klasses per element class. Once the normal
`IndexingTreeEntry[]` klass exists, later setting `_creates_weak_arrays` would
be too late.

That is why `alloc_indexing_table` asserts:

```text
array_klass->is_weak_objArray_klass()
```

This assertion catches the bug where something created a normal
`IndexingTreeEntry[]` before the indexing-tree native allocator marked the
element type.

## KlassKind Integration

HotSpot uses `KlassKind` to dispatch oop iteration. The implementation adds:

```text
WeakObjArrayKlassKind
```

and makes:

```cpp
is_objArray_klass()
```

return true for both:

```text
ObjArrayKlass
WeakObjArrayKlass
```

This preserves general object-array behavior while still allowing special tests:

```cpp
is_weak_objArray_klass()
```

The iterator dispatch tables also register `WeakObjArrayKlass`, so closures
that iterate heap objects call the custom methods instead of falling back to
ordinary object-array iteration.

## Core Iteration Design

The central predicate is:

```cpp
weak_objarray_suppress(closure)
```

Simplified:

```text
if WeakArrayScanScope::YoungScan:
  suppress element scanning

else if WeakArrayScanScope::StrongMark
     and closure mode is DO_DISCOVERY:
  suppress element scanning

else:
  scan elements normally
```

The actual iteration method has this shape:

```cpp
if closure wants metadata:
  visit array klass metadata

if weak_objarray_suppress(closure):
  return

scan array elements normally
```

This is subtle but important:

```text
Suppression only applies to array elements, not array metadata.
```

The VM can still process the array's klass metadata when needed.

## The Three Iteration Variants

`WeakObjArrayKlass` overrides three forms:

```cpp
oop_oop_iterate
oop_oop_iterate_reverse
oop_oop_iterate_bounded
```

### `oop_oop_iterate`

This is the normal object iteration path. It is used when a collector scans the
whole array object.

### `oop_oop_iterate_reverse`

This delegates to the same logic. For this use case, reverse order does not
matter because the only special behavior is "scan elements" or "do not scan
elements."

### `oop_oop_iterate_bounded`

This is critical for card scanning and remembered-set scanning. A collector may
scan only the part of an object that overlaps a memory region or dirty card.

Without a bounded override, a card scan could bypass the weak-array policy and
trace table elements. The bounded method applies the same suppression predicate
before scanning the bounded element range.

## How It Behaves During GC

### Normal execution

No weak scan scope is active.

```text
WeakObjArrayKlass behaves like ObjArrayKlass.
```

The table slots are ordinary Java references as far as normal code is concerned.

### Young GC

`WeakArrayScanScope::YoungScan` is active.

```text
table object may be copied or kept alive
table elements are not automatically scanned
```

This prevents old-to-young remembered-set scanning from promoting/copying every
entry reachable from the table.

After normal young-GC reachability has run, `IndexingTreeManager` walks the
table and asks the collector whether each key is alive. Only surviving bucket
heads are passed to `keep_alive`.

### Full GC discovery marking

`WeakArrayScanScope::StrongMark` is active and the closure mode is
`DO_DISCOVERY`.

```text
table elements are not marked during the initial discovery trace
```

Later, `IndexingTreeManager` removes entries whose keys were not marked from
outside the tree, then explicitly keeps surviving bucket heads alive.

### Pointer adjustment and other non-discovery passes

The closure mode is not `DO_DISCOVERY`.

```text
WeakObjArrayKlass scans elements normally
```

This is needed because moving collectors must update surviving references.
Suppression is for reachability discovery, not for all GC phases.

## Interaction With IndexingTreeManager

`WeakObjArrayKlass` creates a temporary "blind spot" in normal GC tracing:

```text
GC does not automatically see table[i] entries during weak scan modes.
```

`IndexingTreeManager` fills that gap:

```text
for each table slot:
  walk the entry chain manually
  check each entry's keys using collector is_alive
  unlink dead-key entries
  call keep_alive on surviving bucket heads
```

The manager is allowed to do this because it is invoked from
`ReferenceProcessor`, which already has the collector's liveness and keep-alive
closures.

Together:

```text
WeakObjArrayKlass prevents premature tracing.
IndexingTreeManager reintroduces only the live entries.
```

## Interaction With InstanceIndexingTreeKlass

The two custom klasses control different edges:

```text
InstanceIndexingTreeKlass
  controls IndexingTree -> table

WeakObjArrayKlass
  controls table[i] -> entry
```

Sometimes `InstanceIndexingTreeKlass` intentionally traces the table field even
during young GC. For example, if the table array itself is young, it must be
copied. This does not necessarily break weak-key behavior, because
`WeakObjArrayKlass` can still suppress scanning of the table's elements.

So the design separates:

```text
keeping the table object valid
from
keeping the table contents alive
```

That separation is the main reason the design needs both custom klasses.

## Parallel GC Pitfall

Some Parallel GC paths process large object arrays through chunking code that
can scan array elements directly instead of going through normal klass dispatch.

That is dangerous:

```text
raw array chunk scan
  -> table element
  -> entry
  -> keys
```

would bypass `WeakObjArrayKlass::oop_oop_iterate`.

The implementation adds guards in Parallel GC paths to detect
`is_weak_objArray_klass()` and avoid chunk processing during weak scan modes.

This is a general rule for this design:

```text
Every object-array scanning path must either dispatch through the klass
or explicitly respect WeakObjArrayKlass.
```

## Design Invariants

### Invariant 1: Java type identity is preserved

The array is still an `IndexingTreeEntry[]` to Java code. The special behavior is
only in HotSpot's internal `Klass`.

### Invariant 2: Suppression is phase-scoped

The array is not always weakly scanned. Suppression happens only during
`YoungScan` or strong-mark discovery.

### Invariant 3: Metadata is still visited

Even when element scanning is suppressed, the array's klass metadata can still
be visited if the closure requests it.

### Invariant 4: Cleanup is external

`WeakObjArrayKlass` must not decide which slots are live. It only prevents
automatic tracing. `IndexingTreeManager` does the semantic cleanup.

### Invariant 5: Moving collectors still need updates

The suppression policy must not hide references during pointer adjustment or
other relocation/update passes. That is why the full-GC suppression also checks
the closure's reference iteration mode.

## Why This Design Is Reasonable

The design is narrow:

```text
Only IndexingTreeEntry[] bucket arrays get this special klass.
```

It is also minimally invasive:

```text
The Java data structure does not need WeakReference objects.
The entries remain ordinary Java objects.
The table remains an ordinary Java array from the language perspective.
Collectors continue using their own liveness and keep-alive closures.
```

And it solves the key GC issue:

```text
The table can exist strongly, but its slots do not automatically keep all
entries and keys alive during weak-key cleanup.
```

## Advisor-Level Explanation

You can explain `WeakObjArrayKlass` like this:

> `WeakObjArrayKlass` is a custom HotSpot metadata class for the indexing tree's
> bucket array. Java still sees the array as `IndexingTreeEntry[]`, but when GC
> iterates that array during young collection or discovery marking, the custom
> klass visits metadata and then skips the elements. That prevents the table
> slots from making every entry and key strongly reachable. Later, during
> reference processing, `IndexingTreeManager` walks the table manually, removes
> entries whose keys are dead, and calls the collector's `keep_alive` closure on
> the surviving bucket heads. So `WeakObjArrayKlass` is the mechanism that
> delays tracing of table elements until after weak-key liveness has been
> decided.

