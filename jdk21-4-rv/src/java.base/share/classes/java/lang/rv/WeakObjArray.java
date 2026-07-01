/*
 * Copyright (c) 2026, The NAITAE authors.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  The NAITAE authors designate
 * this particular file as subject to the "Classpath" exception as provided
 * in the LICENSE file that accompanied this code.
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

package java.lang.rv;

/**
 * Allocator for object arrays whose element slots are scan-suppressed
 * by GC during {@code YoungScan} and {@code StrongMark}-with-discovery
 * phases.  Returned arrays have static type {@code Object[]} but are
 * backed by HotSpot's {@code WeakObjArrayKlass}; cleanup of dead
 * referents is the caller's responsibility (e.g. via
 * {@code IndexingTreeManager}).
 */
public final class WeakObjArray {
    private WeakObjArray() {}

    private static native void registerNatives();
    static { registerNatives(); }

    /**
     * Allocate an {@code Object[length]} backed by a WeakObjArrayKlass.
     * Element type is {@code java.lang.Object}; cast slot reads as needed.
     * @param length array length
     * @return the allocated weakly-scanned array
     */
    public static native Object[] allocate(int length);
}
