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
#include "classfile/javaClasses.inline.hpp"
#include "gc/shared/collectedHeap.hpp"
#include "gc/shared/genCollectedHeap.hpp"
#include "gc/shared/oopStorage.inline.hpp"
#include "gc/shared/oopStorageSet.hpp"
#include "gc/shared/weakArrayScanScope.hpp"
#include "logging/log.hpp"
#include "oops/objArrayOop.inline.hpp"
#include "oops/oop.inline.hpp"
#include "runtime/atomic.hpp"
#include "runtime/mutex.hpp"
#include "runtime/mutexLocker.hpp"
#include "utilities/indexingTreeManager.hpp"
#if INCLUDE_PARALLELGC
#include "gc/parallel/parallelScavengeHeap.inline.hpp"
#endif
#if INCLUDE_G1GC
#include "gc/g1/g1CollectedHeap.inline.hpp"
#endif

OopStorage* IndexingTreeManager::_tree_storage = nullptr;
GrowableArrayCHeap<oop*, mtGC>* IndexingTreeManager::_tree_slots = nullptr;
Mutex* IndexingTreeManager::_slots_lock = nullptr;
static const uintx IndexingTreeDrainInterval = 256;

static bool key_is_alive(oop key, BoolObjectClosure* is_alive) {
  return key == nullptr || is_alive->do_object_b(key);
}

template <typename T>
static void keep_table_field_alive(oop tree, OopClosure* keep_alive) {
  keep_alive->do_oop(tree->field_addr<T>(java_lang_rv_IndexingTree::table_offset()));
}

static void maybe_drain_marking(size_t* refs_since_drain, VoidClosure* complete_gc) {
  if (complete_gc != nullptr && *refs_since_drain >= IndexingTreeDrainInterval) {
    complete_gc->do_void();
    *refs_since_drain = 0;
  }
}

void IndexingTreeManager::initialize() {
  _tree_storage = OopStorageSet::create_strong("IndexingTree", mtGC);
  _tree_slots = new GrowableArrayCHeap<oop*, mtGC>(64);
  _slots_lock = new Mutex(Mutex::nosafepoint, "IndexingTreeSlots_lock");
}

void IndexingTreeManager::add_tree(oop tree) {
  oop* handle = _tree_storage->allocate();
  *handle = tree;
  // Publish into the parallel slot index used by MT cleanup.  Cleanup
  // runs at safepoint so reads are stable; mutators are the only writers.
  MutexLocker ml(_slots_lock, Mutex::_no_safepoint_check_flag);
  _tree_slots->append(handle);
}

bool IndexingTreeManager::table_is_in_young(oop tree) {
  objArrayOop table = java_lang_rv_IndexingTree::table(tree);
  if (table == nullptr) return false;
#if INCLUDE_PARALLELGC
  if (UseParallelGC) return ParallelScavengeHeap::heap()->is_in_young(table);
#endif
#if INCLUDE_G1GC
  if (UseG1GC) return G1CollectedHeap::heap()->is_in_young(table);
#endif
  return GenCollectedHeap::heap()->is_in_young(table);
}

bool IndexingTreeManager::obj_is_in_young(oop obj) {
  if (obj == nullptr) return false;
#if INCLUDE_PARALLELGC
  if (UseParallelGC) return ParallelScavengeHeap::heap()->is_in_young(obj);
#endif
#if INCLUDE_G1GC
  if (UseG1GC) return G1CollectedHeap::heap()->is_in_young(obj);
#endif
  return GenCollectedHeap::heap()->is_in_young(obj);
}

// Scan a range of buckets, unlinking entries whose keys are dead.
// Only writes to slots / next pointers when the bucket changed — avoids
// dirtying cards unnecessarily.
static void clean_bucket_range(objArrayOop table_array, int start, int end,
                                BoolObjectClosure* is_alive,
                                int& dead_out, int& alive_out) {
  int dead = 0, alive = 0;
  for (int i = start; i < end; i++) {
    oop prev = nullptr;
    oop entry = table_array->obj_at(i);
    oop first_alive = nullptr;
    bool bucket_changed = false;

    while (entry != nullptr) {
      oop next_entry = java_lang_rv_IndexingTreeEntry::next(entry);

      objArrayOop keys = java_lang_rv_IndexingTreeEntry::keys(entry);
      bool all_keys_alive = true;
      if (keys != nullptr) {
        int num_keys = keys->length();
        for (int k = 0; k < num_keys; k++) {
          if (!key_is_alive(keys->obj_at(k), is_alive)) {
            all_keys_alive = false;
            break;
          }
        }
      }

      if (all_keys_alive) {
        if (first_alive == nullptr) first_alive = entry;
        if (prev != nullptr && java_lang_rv_IndexingTreeEntry::next(prev) != entry) {
          java_lang_rv_IndexingTreeEntry::set_next(prev, entry);
          bucket_changed = true;
        }
        prev = entry;
        alive++;
      } else {
        dead++;
        bucket_changed = true;
      }
      entry = next_entry;
    }

    if (bucket_changed) {
      if (prev != nullptr) {
        java_lang_rv_IndexingTreeEntry::set_next(prev, (oop)nullptr);
      }
      table_array->obj_at_put(i, first_alive);
    }
  }
  dead_out = dead;
  alive_out = alive;
}

// Phase 1 (unlink dead entries) + Phase 2 (keep surviving chains alive).
// Young GC uses forwarding-based is_alive; full GC uses mark bits.  Full
// GC additionally needs to keep the table object itself alive.
static void clean_tree_impl(objArrayOop table_array, int table_length,
                             BoolObjectClosure* is_alive,
                             OopClosure* keep_alive,
                             VoidClosure* complete_gc,
                             oop tree,
                             bool is_young_gc) {
  int dead = 0, alive = 0;
  clean_bucket_range(table_array, 0, table_length, is_alive, dead, alive);

  int old_size = java_lang_rv_IndexingTree::size_value(tree);
  java_lang_rv_IndexingTree::set_size(tree, old_size - dead);
  if (dead > 0) {
    log_debug(gc, phases)("IndexingTree %s cleanup: removed %d dead entries, %d alive",
                          is_young_gc ? "young" : "full", dead, alive);
  }

  if (!is_young_gc) {
    // Mark the table array via the tree's table field; otherwise sweep
    // reclaims it.  Full-GC adjustment may relocate it, so re-read.
    if (UseCompressedOops) {
      keep_table_field_alive<narrowOop>(tree, keep_alive);
    } else {
      keep_table_field_alive<oop>(tree, keep_alive);
    }
    if (complete_gc != nullptr) complete_gc->do_void();

    table_array = java_lang_rv_IndexingTree::table(tree);
    if (table_array == nullptr) return;
  }

  size_t refs_since_drain = 0;
  int skipped_old_heads = 0;
  for (int i = 0; i < table_length; i++) {
    oop head = table_array->obj_at(i);
    if (head == nullptr) continue;

    // Parallel Scavenge ONLY: skip keep_alive on old-gen bucket heads.
    // PSKeepAliveClosure has no runtime guard (only an `#ifdef ASSERT` check),
    // so applied to an old-gen head it copies the live old-gen entry into
    // survivor space and installs a forwarding pointer in it -> heap corruption
    // that a later young GC follows into freed memory (SIGSEGV in
    // copy_unmarked_to_survivor_space).  In a PS scavenge old gen never moves,
    // so old heads need no keep_alive and skipping is correct.
    //
    // This skip must NOT apply to Serial/G1: their keep-alive closures already
    // guard (Serial `if (is_in_young_gen)`, G1 `if (is_in_cset)`), so old heads
    // are safe, AND on a G1 *mixed* pause an old entry in the collection set
    // MUST be kept alive here so it is evacuated and its slot updated -- else
    // it is reclaimed, leaving a dangling slot that crashes clean_bucket_range.
    if (is_young_gc && UseParallelGC && !IndexingTreeManager::obj_is_in_young(head)) {
      skipped_old_heads++;
      continue;
    }

    if (UseCompressedOops) {
      keep_alive->do_oop(&((narrowOop*)table_array->base())[i]);
    } else {
      keep_alive->do_oop(&((oop*)table_array->base())[i]);
    }
    refs_since_drain++;
    maybe_drain_marking(&refs_since_drain, complete_gc);
  }
  if (is_young_gc && skipped_old_heads > 0) {
    log_debug(gc, phases)("IndexingTree young cleanup: skipped keep_alive on %d old-gen bucket heads",
                          skipped_old_heads);
  }
  if (complete_gc != nullptr) complete_gc->do_void();
}

void IndexingTreeManager::clean_tree(oop tree,
                                      BoolObjectClosure* is_alive,
                                      OopClosure* keep_alive,
                                      VoidClosure* complete_gc) {
  objArrayOop table_array = java_lang_rv_IndexingTree::table(tree);
  if (table_array == nullptr) return;

  bool young_gc = WeakArrayScanScope::in(WeakArrayScanScope::YoungScan);

  int table_length = java_lang_rv_IndexingTree::capacity_value(tree);

  // During young GC interleaved with G1 concurrent marking (YoungScan +
  // StrongMark composite), key liveness is unknowable mid-mark.  We can't
  // run normal cleanup, but we *must* propagate liveness to every entry —
  // otherwise young-gen entries reachable only via the suppressed bucket
  // array slots have no live root and the young GC reclaims them, leaving
  // dangling slot pointers that crash the next non-interleaved cleanup.
  // Conservative pass: keep_alive every non-null bucket slot, defer
  // pruning to the next non-interleaved cleanup.
  if (young_gc && WeakArrayScanScope::in(WeakArrayScanScope::StrongMark)) {
    for (int i = 0; i < table_length; i++) {
      if (table_array->obj_at(i) == nullptr) continue;
      if (UseCompressedOops)
        keep_alive->do_oop(&((narrowOop*)table_array->base())[i]);
      else
        keep_alive->do_oop(&((oop*)table_array->base())[i]);
    }
    if (complete_gc != nullptr) complete_gc->do_void();
    return;
  }

  clean_tree_impl(table_array, table_length, is_alive, keep_alive, complete_gc, tree, young_gc);
}

// Phase 1 + Phase 2 cleanup of one tree given its slot address.  Used by
// both single-threaded and indexed-MT iteration.
static inline void clean_one_slot(oop* slot,
                                  BoolObjectClosure* is_alive,
                                  OopClosure* keep_alive,
                                  VoidClosure* complete_gc) {
  oop tree = *slot;
  if (tree != nullptr) {
    IndexingTreeManager::clean_tree(tree, is_alive, keep_alive, complete_gc);
  }
}

void IndexingTreeManager::clean_all_trees(BoolObjectClosure* is_alive,
                                           OopClosure* keep_alive,
                                           VoidClosure* complete_gc) {
  if (_tree_slots == nullptr) return;
  int n = _tree_slots->length();
  for (int i = 0; i < n; i++) {
    clean_one_slot(_tree_slots->at(i), is_alive, keep_alive, complete_gc);
  }
  log_debug(gc, phases)("IndexingTree: processed %d trees (single-threaded)", n);
}

void IndexingTreeManager::clean_trees_par_indexed(volatile uint* counter,
                                                   BoolObjectClosure* is_alive,
                                                   OopClosure* keep_alive,
                                                   VoidClosure* complete_gc) {
  if (_tree_slots == nullptr) return;
  uint n = (uint) _tree_slots->length();
  uint claimed_by_me = 0;
  while (true) {
    // Atomic claim of one tree.  Workers race on `counter`; granularity
    // is one tree, so each worker can do useful work even when registry
    // size < OopStorage block size.
    uint idx = Atomic::fetch_then_add(counter, 1u);
    if (idx >= n) break;
    clean_one_slot(_tree_slots->at((int) idx), is_alive, keep_alive, complete_gc);
    claimed_by_me++;
  }
  log_debug(gc, phases)("IndexingTree: worker processed %u of %u trees", claimed_by_me, n);
}

// Phase 1 only, for collectors whose marking is complete at cleanup time
// (Shenandoah, ZGC) — survivors are already marked, no keep_alive needed.
static inline void clean_one_slot_marked(oop* slot, BoolObjectClosure* is_alive) {
  oop tree = *slot;
  if (tree == nullptr) return;
  objArrayOop table_array = java_lang_rv_IndexingTree::table(tree);
  if (table_array == nullptr) return;
  int table_length = java_lang_rv_IndexingTree::capacity_value(tree);
  int dead = 0, alive = 0;
  clean_bucket_range(table_array, 0, table_length, is_alive, dead, alive);
  if (dead > 0) {
    int old_size = java_lang_rv_IndexingTree::size_value(tree);
    java_lang_rv_IndexingTree::set_size(tree, old_size - dead);
    log_debug(gc, phases)("IndexingTree cleanup: removed %d dead entries, %d alive", dead, alive);
  }
}

void IndexingTreeManager::clean_all_trees_marked(BoolObjectClosure* is_alive) {
  if (_tree_slots == nullptr) return;
  int n = _tree_slots->length();
  for (int i = 0; i < n; i++) {
    clean_one_slot_marked(_tree_slots->at(i), is_alive);
  }
  log_debug(gc, phases)("IndexingTree: processed %d trees (mark-only, single-threaded)", n);
}

void IndexingTreeManager::clean_trees_marked_par_indexed(volatile uint* counter,
                                                         BoolObjectClosure* is_alive) {
  if (_tree_slots == nullptr) return;
  uint n = (uint) _tree_slots->length();
  uint claimed_by_me = 0;
  while (true) {
    uint idx = Atomic::fetch_then_add(counter, 1u);
    if (idx >= n) break;
    clean_one_slot_marked(_tree_slots->at((int) idx), is_alive);
    claimed_by_me++;
  }
  log_debug(gc, phases)("IndexingTree: worker processed %u of %u trees (mark-only)", claimed_by_me, n);
}
