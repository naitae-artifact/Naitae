#ifndef SHARE_GC_SHARED_WEAKARRAYSCANSCOPE_HPP
#define SHARE_GC_SHARED_WEAKARRAYSCANSCOPE_HPP

#include "memory/allocation.hpp"
#include "utilities/globalDefinitions.hpp"

// RAII scope object declaring that the current GC phase suppresses
// scanning of weak-array klasses (currently the IndexingTree bucket
// array).  Single source of truth for GC-phase state read by the
// suppression predicates in objArrayKlass.inline.hpp and
// instanceIndexingTreeKlass.inline.hpp.
//
// Bits compose: nested scopes OR their modes; on exit, only the bits
// the scope itself added are cleared.  This matches the prior semantics
// where YoungScan and G1Mixed could overlap during a G1 mixed pause.

class WeakArrayScanScope : public StackObj {
 public:
  enum Mode : uint8_t {
    None       = 0,
    YoungScan  = 1 << 0,  // young-GC scavenge / card scan
    StrongMark = 1 << 1,  // full-GC DO_DISCOVERY marking
    G1Mixed    = 1 << 2,  // G1 mixed collection: old-gen evacuation active
  };

 private:
  uint8_t _added;

 public:
  explicit WeakArrayScanScope(uint8_t modes);
  ~WeakArrayScanScope();

  static uint8_t current();
  static bool    in(Mode m);

  // Non-RAII set/clear. Used by G1 concurrent marking, where the mode
  // is entered on the concurrent-mark thread in mark_from_roots() and
  // cleared later in weak_refs_work() — no single stack frame bounds
  // the region.
  static void enter(Mode m);
  static void leave(Mode m);
};

#endif // SHARE_GC_SHARED_WEAKARRAYSCANSCOPE_HPP
