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

#include "precompiled.hpp"
#include "classfile/classFileParser.hpp"
#include "classfile/javaClasses.hpp"
#include "oops/instanceIndexingTreeKlass.inline.hpp"
#include "oops/oop.inline.hpp"

InstanceIndexingTreeKlass::InstanceIndexingTreeKlass(const ClassFileParser& parser)
  : InstanceKlass(parser, Kind) {}

void InstanceIndexingTreeKlass::update_nonstatic_oop_maps(Klass* k) {
  // Remove the table field from the oop maps so normal GC traversal
  // never sees it. The table is the only oop field in IndexingTree;
  // the remaining fields are primitive metadata.
  // oop_oop_iterate handles the table explicitly based on
  // reference_iteration_mode().
  InstanceKlass* ik = InstanceKlass::cast(k);

  assert(ik->nonstatic_oop_map_count() == 1, "IndexingTree should have exactly one oop field (table)");

  OopMapBlock* map = ik->start_of_nonstatic_oop_maps();
  assert(map->count() == 1, "table should be the only oop field");

  map->set_count(0);
}
