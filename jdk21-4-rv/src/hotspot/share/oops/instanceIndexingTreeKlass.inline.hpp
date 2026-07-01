/*
 * Copyright (c) 2026, The NAITAE authors.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#ifndef SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_INLINE_HPP
#define SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_INLINE_HPP

#include "oops/instanceIndexingTreeKlass.hpp"

#include "classfile/javaClasses.hpp"
#include "gc/shared/weakArrayScanScope.hpp"
#include "oops/instanceKlass.inline.hpp"
#include "oops/oop.inline.hpp"
#include "utilities/devirtualizer.inline.hpp"
#include "utilities/globalDefinitions.hpp"
#include "utilities/indexingTreeManager.hpp"

// GC traversal for IndexingTree objects.  The table field is excluded
// from the oop maps (update_nonstatic_oop_maps) so the parent
// InstanceKlass::oop_oop_iterate sees no oop fields; we add it back
// here, gated by GC phase.

template <typename T, class OopClosureType>
inline void InstanceIndexingTreeKlass::do_table(oop obj, OopClosureType* closure) {
  T* table_addr = obj->field_addr<T>(java_lang_rv_IndexingTree::table_offset());
  Devirtualizer::do_oop(closure, table_addr);
}

template <class OopClosureType>
inline bool InstanceIndexingTreeKlass::should_skip_table(oop obj, OopClosureType* closure) {
  using S = WeakArrayScanScope;
  if (S::in(S::YoungScan)) {
    // During G1 concurrent marking interleaved with young GC, trace the
    // table normally so entries are incrementally marked across pauses.
    if (S::in(S::StrongMark)) return false;
    // G1 mixed GC evacuates old-gen regions, so the bucket array can move.
    if (S::in(S::G1Mixed)) return false;
    // Young-gen tables (just after resize) must be traced so the
    // scavenger copies them; otherwise they get collected.
    if (IndexingTreeManager::table_is_in_young(obj)) return false;
    return true;
  }
  if (S::in(S::StrongMark) &&
      closure->reference_iteration_mode() == OopIterateClosure::DO_DISCOVERY) return true;
  return false;
}

template <typename T, class OopClosureType>
inline void InstanceIndexingTreeKlass::oop_oop_iterate(oop obj, OopClosureType* closure) {
  InstanceKlass::oop_oop_iterate<T>(obj, closure);

  if (!should_skip_table(obj, closure)) {
    do_table<T>(obj, closure);
  }
}

template <typename T, class OopClosureType>
inline void InstanceIndexingTreeKlass::oop_oop_iterate_reverse(oop obj, OopClosureType* closure) {
  InstanceKlass::oop_oop_iterate_reverse<T>(obj, closure);

  if (!should_skip_table(obj, closure)) {
    do_table<T>(obj, closure);
  }
}

template <typename T, class OopClosureType>
inline void InstanceIndexingTreeKlass::oop_oop_iterate_bounded(oop obj, OopClosureType* closure, MemRegion mr) {
  InstanceKlass::oop_oop_iterate_bounded<T>(obj, closure, mr);

  if (!should_skip_table(obj, closure)) {
    T* table_addr = obj->field_addr<T>(java_lang_rv_IndexingTree::table_offset());
    if (mr.contains(table_addr)) {
      Devirtualizer::do_oop(closure, table_addr);
    }
  }
}

#endif // SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_INLINE_HPP
