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

/** Hash table entry node for IndexingTree. */
public class IndexingTreeEntry {
    /** Hash code of the keys.  Final so the value is visible to
     *  concurrent readers via JMM final-field freeze semantics. */
    protected final int hashCode;
    /** Identity keys for this entry.  Final so concurrent readers that
     *  observe the entry via a non-volatile {@code data[index]} publication
     *  see a fully-initialized keys array rather than a partial/stale
     *  reference.  Without this, C2-compiled concurrent lookups can
     *  dereference a garbage keys pointer on collectors whose young-GC
     *  cadence exposes the publication race (observed on G1+pmd). */
    protected final Object[] keys;
    /** The associated monitor value.  Mutable because Java put() may
     *  replace an existing entry's value. */
    protected Object value;
    /** Next entry in the hash chain.  Mutable because both Java put()
     *  and GC cleanup update this field. */
    protected IndexingTreeEntry next;

    /**
     * Creates a new entry with the given hash code, keys, and chain pointer.
     * @param hashCode the hash code of the keys
     * @param keys the identity keys
     * @param next the next entry in the chain, or {@code null}
     */
    public IndexingTreeEntry(int hashCode, Object[] keys, IndexingTreeEntry next){
        this.hashCode = hashCode;
        this.keys = keys;
        this.next = next;
    }
}
