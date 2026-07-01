#ifndef SHARE_OOPS_WEAKOBJARRAYKLASS_HPP
#define SHARE_OOPS_WEAKOBJARRAYKLASS_HPP

#include "oops/objArrayKlass.hpp"

// Object-array klass whose slots are weak references for GC purposes.
// During phases declared via WeakArrayScanScope (YoungScan / StrongMark),
// oop_oop_iterate returns without visiting any slot. Clients responsible
// for discovering surviving slots via their own cleanup pass during
// reference processing (see IndexingTreeManager for the first consumer).
//
// Allocation is via java.lang.rv.WeakObjArray.allocate (for Object[]) or
// internally by alloc_indexing_table (for IndexingTreeEntry[]).  Both
// bypass InstanceKlass::array_klass and cache a dedicated WeakObjArrayKlass
// instance per element type, so the regular ObjArrayKlass for that element
// type (used by ordinary `new T[N]`) remains the cached _array_klasses.

class WeakObjArrayKlass : public ObjArrayKlass {
  friend class VMStructs;

 public:
  static const KlassKind Kind = WeakObjArrayKlassKind;

  WeakObjArrayKlass() {}  // CDS
  WeakObjArrayKlass(int n, Klass* element_klass, Symbol* name);

  static WeakObjArrayKlass* allocate(ClassLoaderData* loader_data,
                                     int n, Klass* k, Symbol* name, TRAPS);

  DEBUG_ONLY(bool is_weak_objArray_klass_slow() const { return true; })

  static WeakObjArrayKlass* cast(Klass* k) {
    assert(k->is_weak_objArray_klass(), "cast to WeakObjArrayKlass");
    return static_cast<WeakObjArrayKlass*>(k);
  }

  // Iterate over oop elements and metadata.  The suppression predicate
  // (WeakArrayScanScope) is consulted before any slot is visited.
  template <typename T, class OopClosureType>
  inline void oop_oop_iterate(oop obj, OopClosureType* closure);

  template <typename T, class OopClosureType>
  inline void oop_oop_iterate_reverse(oop obj, OopClosureType* closure);

  template <typename T, class OopClosureType>
  inline void oop_oop_iterate_bounded(oop obj, OopClosureType* closure, MemRegion mr);
};

#endif // SHARE_OOPS_WEAKOBJARRAYKLASS_HPP
