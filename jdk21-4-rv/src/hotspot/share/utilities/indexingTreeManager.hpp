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

#ifndef SHARE_UTILITIES_INDEXINGTREEMANAGER_HPP
#define SHARE_UTILITIES_INDEXINGTREEMANAGER_HPP

#include "gc/shared/oopStorage.hpp"
#include "memory/allStatic.hpp"
#include "memory/iterator.hpp"
#include "oops/oopsHierarchy.hpp"
#include "utilities/growableArray.hpp"

class Mutex;

// Registry of IndexingTree objects and the cleanup algorithm that runs
// during GC reference processing.
//
// Phase 1 — walk each tree's table, check key liveness via is_alive,
//   unlink dead entries, rebuild chains.
// Phase 2 — keep surviving bucket heads alive via keep_alive; drain
//   follows the chain through each entry's oop_map.
//
// The tree registry uses strong OopStorage so pointer adjustment happens
// automatically across all collectors.  In parallel to the OopStorage we
// keep _tree_slots — a flat array of slot addresses — so that MT cleanup
// can claim trees one at a time via an atomic counter (per-tree
// granularity), bypassing OopStorage's coarser per-block claim.

class IndexingTreeManager : AllStatic {
 private:
  static OopStorage* _tree_storage;
  // Slot pointers, appended on add_tree, never released.  OopStorage owns
  // the oop values (root tracing, pointer adjustment); this array is just
  // an index for parallel claims at cleanup time.  Slot addresses are
  // stable for the slot's lifetime — OopStorage blocks live in C-heap and
  // are not relocated, and we never release.
  static GrowableArrayCHeap<oop*, mtGC>* _tree_slots;
  static Mutex* _slots_lock;  // mutator-vs-mutator on add_tree only

 public:
  // Phase 1 + Phase 2 cleanup of a single tree.  Public because both
  // single-threaded and indexed-MT iteration call into it from outside
  // the class via the free clean_one_slot helper.
  static void clean_tree(oop tree,
                         BoolObjectClosure* is_alive,
                         OopClosure* keep_alive,
                         VoidClosure* complete_gc);

  static void initialize();
  static void add_tree(oop tree);

  static OopStorage* tree_storage() { return _tree_storage; }

  // Single-threaded entry: walks every registered tree.
  static void clean_all_trees(BoolObjectClosure* is_alive,
                              OopClosure* keep_alive,
                              VoidClosure* complete_gc);

  // Multi-worker entry.  All workers pass the SAME counter pointer; each
  // worker atomically claims one tree at a time until the counter reaches
  // the registered tree count.  complete_gc may be nullptr (skip in-cleanup
  // drains; caller is expected to drive a converging drain afterwards).
  static void clean_trees_par_indexed(volatile uint* counter,
                                      BoolObjectClosure* is_alive,
                                      OopClosure* keep_alive,
                                      VoidClosure* complete_gc);

  // Phase 1 only, for collectors whose marks are complete at cleanup time
  // (Shenandoah, ZGC).
  static void clean_all_trees_marked(BoolObjectClosure* is_alive);
  static void clean_trees_marked_par_indexed(volatile uint* counter,
                                             BoolObjectClosure* is_alive);

  // True if the tree's table Object[] is in young gen.
  static bool table_is_in_young(oop tree);

  // True if an arbitrary oop is in young gen (collector-agnostic dispatch).
  // Used to gate keep_alive during young GC: a young-GC keep_alive closure
  // may only be applied to young-gen referents.
  static bool obj_is_in_young(oop obj);
};

#endif // SHARE_UTILITIES_INDEXINGTREEMANAGER_HPP
