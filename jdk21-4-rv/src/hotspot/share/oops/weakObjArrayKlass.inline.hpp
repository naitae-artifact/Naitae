#ifndef SHARE_OOPS_WEAKOBJARRAYKLASS_INLINE_HPP
#define SHARE_OOPS_WEAKOBJARRAYKLASS_INLINE_HPP

#include "oops/weakObjArrayKlass.hpp"

#include "gc/shared/weakArrayScanScope.hpp"
#include "memory/iterator.hpp"
#include "memory/memRegion.hpp"
#include "oops/arrayOop.hpp"
#include "oops/objArrayKlass.inline.hpp"
#include "oops/objArrayOop.inline.hpp"
#include "oops/oop.inline.hpp"
#include "utilities/devirtualizer.inline.hpp"
#include "utilities/macros.hpp"

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
  assert(obj->is_array(), "obj must be array");
  objArrayOop a = objArrayOop(obj);

  if (Devirtualizer::do_metadata(closure)) {
    Devirtualizer::do_klass(closure, obj->klass());
  }

  if (weak_objarray_suppress(closure)) return;

  ObjArrayKlass::oop_oop_iterate_elements<T>(a, closure);
}

template <typename T, class OopClosureType>
void WeakObjArrayKlass::oop_oop_iterate_reverse(oop obj, OopClosureType* closure) {
  oop_oop_iterate<T>(obj, closure);
}

template <typename T, class OopClosureType>
void WeakObjArrayKlass::oop_oop_iterate_bounded(oop obj, OopClosureType* closure, MemRegion mr) {
  assert(obj->is_array(), "obj must be array");
  objArrayOop a = objArrayOop(obj);

  if (Devirtualizer::do_metadata(closure)) {
    Devirtualizer::do_klass(closure, a->klass());
  }

  if (weak_objarray_suppress(closure)) return;

  ObjArrayKlass::oop_oop_iterate_elements_bounded<T>(a, closure, mr.start(), mr.end());
}

#endif // SHARE_OOPS_WEAKOBJARRAYKLASS_INLINE_HPP
