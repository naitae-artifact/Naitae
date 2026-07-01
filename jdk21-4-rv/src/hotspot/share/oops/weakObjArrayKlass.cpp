#include "precompiled.hpp"
#include "classfile/classLoaderData.hpp"
#include "memory/metaspace.hpp"
#include "oops/arrayKlass.inline.hpp"
#include "oops/instanceKlass.hpp"
#include "oops/klass.inline.hpp"
#include "oops/weakObjArrayKlass.hpp"

WeakObjArrayKlass::WeakObjArrayKlass(int n, Klass* element_klass, Symbol* name) : ObjArrayKlass(n, element_klass, name, Kind) {}

WeakObjArrayKlass* WeakObjArrayKlass::allocate(ClassLoaderData* loader_data, int n, Klass* k, Symbol* name, TRAPS) {
  assert(ObjArrayKlass::header_size() <= InstanceKlass::header_size(), "array klasses must be same size as InstanceKlass");
  int size = ArrayKlass::static_size(ObjArrayKlass::header_size());
  return new (loader_data, size, THREAD) WeakObjArrayKlass(n, k, name);
}
