#include "precompiled.hpp"
#include "gc/shared/weakArrayScanScope.hpp"

// Composite of all currently-active scope modes. Read by suppression
// predicates in objArrayKlass.inline.hpp and instanceIndexingTreeKlass.inline.hpp.
//
// Threading: written from a single VM coordinator thread under safepoint
// synchronization for STW phases; for G1 concurrent marking, written from
// the concurrent-mark thread, read by mutator/refinement threads. The
// pre-refactor static flags used the same plain-bool model — preserved.

static uint8_t _composite_mode = 0;

WeakArrayScanScope::WeakArrayScanScope(uint8_t modes) {
  _added = modes & ~_composite_mode;
  _composite_mode |= _added;
}

WeakArrayScanScope::~WeakArrayScanScope() {
  _composite_mode &= ~_added;
}

uint8_t WeakArrayScanScope::current()  { return _composite_mode; }
bool    WeakArrayScanScope::in(Mode m) { return (_composite_mode & m) != 0; }

void WeakArrayScanScope::enter(Mode m) { _composite_mode |= m;  }
void WeakArrayScanScope::leave(Mode m) { _composite_mode &= ~m; }
