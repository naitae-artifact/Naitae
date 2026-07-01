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

#ifndef SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_HPP
#define SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_HPP

#include "oops/instanceKlass.hpp"
#include "utilities/macros.hpp"

class ClassFileParser;

// Specialized InstanceKlass for java.lang.rv.IndexingTree.
//
// The table field is removed from the oop maps at class load time
// so normal GC traversal never sees it. The table is handled
// explicitly in oop_oop_iterate based on reference_iteration_mode():
//
//   DO_DISCOVERY (default):  skip table (marking, push_contents)
//   DO_FIELDS / etc.:        trace table (adjustment, card scanning)
//
// This follows the same pattern as InstanceRefKlass, which removes
// the referent and discovered fields from oop maps and handles them
// based on reference_iteration_mode() in oop_oop_iterate_ref_processing.

class InstanceIndexingTreeKlass: public InstanceKlass {
  friend class InstanceKlass;
 public:
  static const KlassKind Kind = InstanceIndexingTreeKlassKind;

 private:
  InstanceIndexingTreeKlass(const ClassFileParser& parser);

 public:
  InstanceIndexingTreeKlass() { assert(DumpSharedSpaces || UseSharedSpaces, "only for CDS"); }

  // Remove table from oop maps so parent traversal never sees it.
  static void update_nonstatic_oop_maps(Klass* k);

  template <typename T, class OopClosureType>
  inline void oop_oop_iterate(oop obj, OopClosureType* closure);

  template <typename T, class OopClosureType>
  inline void oop_oop_iterate_reverse(oop obj, OopClosureType* closure);

  template <typename T, class OopClosureType>
  inline void oop_oop_iterate_bounded(oop obj, OopClosureType* closure, MemRegion mr);

 private:
  template <class OopClosureType>
  static inline bool should_skip_table(oop obj, OopClosureType* closure);

  template <typename T, class OopClosureType>
  inline void do_table(oop obj, OopClosureType* closure);
};

#endif // SHARE_OOPS_INSTANCEINDEXINGTREEKLASS_HPP
