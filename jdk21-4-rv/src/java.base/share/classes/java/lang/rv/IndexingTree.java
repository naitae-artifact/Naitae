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

import java.util.concurrent.atomic.AtomicInteger;

/** VM-integrated identity-keyed hash table for RV-Monitor. */
public final class IndexingTree {
    /** Current number of entries. */
    protected int size;
    /** Unique tree identifier. */
    protected final int id = nextId.getAndIncrement();
    /** Resize-up threshold. */
    protected int upThreshold;
    /** Resize-down threshold. */
    protected int downThreshold;
    /** Hash table buckets.  Length equals {@code capacity}. */
    protected IndexingTreeEntry[] table;
    /** Number of buckets; equals {@code table.length}. */
    protected int capacity;
    /** True after the VM has allocated and registered this tree's bucket table. */
    private volatile boolean initialized;

    private static final AtomicInteger nextId = new AtomicInteger(0);
    private static final int DEFAULT_CAPACITY = 1 << 10;
    private static final int MAXIMUM_CAPACITY = 1 << 30;
    private static final float DEFAULT_LOAD_FACTOR = 0.75f;
    private static final float DEFAULT_REDUCE_FACTOR = 0.10f;

    /** Creates a tree with default capacity.  The bucket array is NOT
     * allocated here: {@code table} stays null until the first insert
     * (see {@link #ensureTable}).  A spec whose tree never receives a
     * monitor therefore keeps {@code table == null}, so it is never
     * registered for VM cleanup and never bucket-scanned at GC -- making
     * the large dormant-spec tail (e.g. ~120 of 160 specs on a typical
     * DaCapo run) cost effectively zero in both CPU and memory. */
    public IndexingTree() {
        capacity = DEFAULT_CAPACITY; // 1024
        upThreshold = (int)(DEFAULT_LOAD_FACTOR * capacity);
        downThreshold = (int)(DEFAULT_REDUCE_FACTOR * capacity);
    }

    /** Lazily allocates the bucket array and registers the tree with the VM
     * on the first insert.  The hot path avoids synchronization after the
     * one-time init flag is set; the slow path serializes first insertion so
     * concurrent creators cannot publish different bucket arrays. */
    private void ensureTable() {
        if (!initialized) {
            initOnce();
        }
    }

    private synchronized void initOnce() {
        if (!initialized) {
            init(capacity);
            initialized = true;
        }
    }

    private static native void registerNatives();
    static {
        registerNatives();
    }

    // -------- Lookups --------

    /** Identity-keyed lookup; null if absent.
     * @param keys lookup keys
     * @return matching value or null */
    public Object get(Object ... keys) {
        IndexingTreeEntry[] data = this.table;
        if (data == null) return null;            // dormant tree: nothing stored
        IndexingTreeEntry e = scan(data[hashIndex(computeHashCode(keys), data.length)], keys);
        return e == null ? null : e.value;
    }

    /** Identity-keyed lookup; null if absent.
     * @param key1 lookup key
     * @return matching value or null */
    public Object get1(Object key1) {
        IndexingTreeEntry[] data = this.table;
        if (data == null) return null;            // dormant tree: nothing stored
        IndexingTreeEntry e = scan1(data[hashIndex(computeHashCode(key1), data.length)], key1);
        return e == null ? null : e.value;
    }

    /** Identity-keyed lookup; null if absent.
     * @param key1 first key
     * @param key2 second key
     * @return matching value or null */
    public Object get2(Object key1, Object key2) {
        IndexingTreeEntry[] data = this.table;
        if (data == null) return null;            // dormant tree: nothing stored
        IndexingTreeEntry e = scan2(data[hashIndex(computeHashCode(key1, key2), data.length)], key1, key2);
        return e == null ? null : e.value;
    }

    /** Identity-keyed lookup; null if absent.
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key
     * @return matching value or null */
    public Object get3(Object key1, Object key2, Object key3) {
        IndexingTreeEntry[] data = this.table;
        if (data == null) return null;            // dormant tree: nothing stored
        IndexingTreeEntry e = scan3(data[hashIndex(computeHashCode(key1, key2, key3), data.length)], key1, key2, key3);
        return e == null ? null : e.value;
    }

    /** Identity-keyed lookup; null if absent.
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key
     * @param key4 fourth key
     * @return matching value or null */
    public Object get4(Object key1, Object key2, Object key3, Object key4) {
        IndexingTreeEntry[] data = this.table;
        if (data == null) return null;            // dormant tree: nothing stored
        IndexingTreeEntry e = scan4(data[hashIndex(computeHashCode(key1, key2, key3, key4), data.length)], key1, key2, key3, key4);
        return e == null ? null : e.value;
    }

    /** Identity-keyed insert; replaces any existing mapping.
     * @param value the value to store
     * @param keys lookup keys */
    public void put(Object value, Object ... keys) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(keys);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan(data[idx], keys);
        if (e != null) { e.value = value; return; }
        IndexingTreeEntry n = new IndexingTreeEntry(hash, keys, data[idx]);
        n.value = value;
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
    }

    /** Identity-keyed single-key insert; replaces any existing mapping.
     * This avoids Java varargs treating an Object[] key as the whole key list.
     * @param value the value to store
     * @param key1 lookup key */
    public void put1(Object value, Object key1) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan1(data[idx], key1);
        if (e != null) { e.value = value; return; }
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1}, data[idx]);
        n.value = value;
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
    }

    /** Identity-keyed two-key insert; replaces any existing mapping.
     * @param value the value to store
     * @param key1 first key
     * @param key2 second key */
    public void put2(Object value, Object key1, Object key2) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan2(data[idx], key1, key2);
        if (e != null) { e.value = value; return; }
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2}, data[idx]);
        n.value = value;
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
    }

    /** Identity-keyed three-key insert; replaces any existing mapping.
     * @param value the value to store
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key */
    public void put3(Object value, Object key1, Object key2, Object key3) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2, key3);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan3(data[idx], key1, key2, key3);
        if (e != null) { e.value = value; return; }
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2, key3}, data[idx]);
        n.value = value;
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
    }

    /** Identity-keyed four-key insert; replaces any existing mapping.
     * @param value the value to store
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key
     * @param key4 fourth key */
    public void put4(Object value, Object key1, Object key2, Object key3, Object key4) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2, key3, key4);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan4(data[idx], key1, key2, key3, key4);
        if (e != null) { e.value = value; return; }
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2, key3, key4}, data[idx]);
        n.value = value;
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
    }

    /** Identity-keyed lookup; on miss, inserts {@code monitorFactory.createMonitor()}.
     * @param monitorFactory factory invoked on cache miss
     * @param keys lookup keys
     * @return existing or newly created value */
    public Object getOrCreate(RuntimeMonitorFactory monitorFactory, Object ... keys) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(keys);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan(data[idx], keys);
        if (e != null) return e.value;
        IndexingTreeEntry n = new IndexingTreeEntry(hash, keys, data[idx]);
        n.value = monitorFactory.createMonitor();
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
        return n.value;
    }

    /** Identity-keyed lookup; on miss, inserts {@code monitorFactory.createMonitor()}.
     * @param monitorFactory factory invoked on cache miss
     * @param key1 lookup key
     * @return existing or newly created value */
    public Object getOrCreate1(RuntimeMonitorFactory monitorFactory, Object key1) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan1(data[idx], key1);
        if (e != null) return e.value;
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1}, data[idx]);
        n.value = monitorFactory.createMonitor();
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
        return n.value;
    }

    /** Identity-keyed lookup; on miss, inserts {@code monitorFactory.createMonitor()}.
     * @param monitorFactory factory invoked on cache miss
     * @param key1 first key
     * @param key2 second key
     * @return existing or newly created value */
    public Object getOrCreate2(RuntimeMonitorFactory monitorFactory, Object key1, Object key2) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan2(data[idx], key1, key2);
        if (e != null) return e.value;
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2}, data[idx]);
        n.value = monitorFactory.createMonitor();
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
        return n.value;
    }

    /** Identity-keyed lookup; on miss, inserts {@code monitorFactory.createMonitor()}.
     * @param monitorFactory factory invoked on cache miss
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key
     * @return existing or newly created value */
    public Object getOrCreate3(RuntimeMonitorFactory monitorFactory, Object key1, Object key2, Object key3) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2, key3);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan3(data[idx], key1, key2, key3);
        if (e != null) return e.value;
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2, key3}, data[idx]);
        n.value = monitorFactory.createMonitor();
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
        return n.value;
    }

    /** Identity-keyed lookup; on miss, inserts {@code monitorFactory.createMonitor()}.
     * @param monitorFactory factory invoked on cache miss
     * @param key1 first key
     * @param key2 second key
     * @param key3 third key
     * @param key4 fourth key
     * @return existing or newly created value */
    public Object getOrCreate4(RuntimeMonitorFactory monitorFactory, Object key1, Object key2, Object key3, Object key4) {
        ensureTable();
        IndexingTreeEntry[] data = this.table;
        int hash = computeHashCode(key1, key2, key3, key4);
        int idx = hashIndex(hash, data.length);
        IndexingTreeEntry e = scan4(data[idx], key1, key2, key3, key4);
        if (e != null) return e.value;
        IndexingTreeEntry n = new IndexingTreeEntry(hash, new Object[]{key1, key2, key3, key4}, data[idx]);
        n.value = monitorFactory.createMonitor();
        data[idx] = n;
        size++;
        checkUpCapacity();
        checkDownCapacity();
        return n.value;
    }

    // -------- Bucket scans (arity-specialized for JIT inlining) --------

    private static IndexingTreeEntry scan(IndexingTreeEntry head, Object[] keys) {
        while (head != null) {
            if (head.keys.length == keys.length) {
                int i = 0;
                while (i < keys.length && head.keys[i] == keys[i]) i++;
                if (i == keys.length) return head;
            }
            head = head.next;
        }
        return null;
    }

    private static IndexingTreeEntry scan1(IndexingTreeEntry head, Object k1) {
        while (head != null) {
            if (head.keys.length == 1 && head.keys[0] == k1) return head;
            head = head.next;
        }
        return null;
    }

    private static IndexingTreeEntry scan2(IndexingTreeEntry head, Object k1, Object k2) {
        while (head != null) {
            if (head.keys.length == 2 && head.keys[0] == k1 && head.keys[1] == k2) return head;
            head = head.next;
        }
        return null;
    }

    private static IndexingTreeEntry scan3(IndexingTreeEntry head, Object k1, Object k2, Object k3) {
        while (head != null) {
            if (head.keys.length == 3 && head.keys[0] == k1 && head.keys[1] == k2 && head.keys[2] == k3) return head;
            head = head.next;
        }
        return null;
    }

    private static IndexingTreeEntry scan4(IndexingTreeEntry head, Object k1, Object k2, Object k3, Object k4) {
        while (head != null) {
            if (head.keys.length == 4 && head.keys[0] == k1 && head.keys[1] == k2 && head.keys[2] == k3 && head.keys[3] == k4) return head;
            head = head.next;
        }
        return null;
    }

    // -------- Hashing --------

    // Callers pass the live table length (data.length), not the capacity
    // field.  The native resize publishes capacity and table as separate
    // non-atomic stores, so a concurrent reader could otherwise pair a new
    // (larger) capacity with the old (smaller) table and index out of
    // bounds.  table.length always equals capacity and both are powers of
    // two, so masking with the loaded array's length is exact and crash-free.
    private int hashIndex(int hashCode, int tableLength) {
        return hashCode & (tableLength - 1);
    }

    private int computeHashCode(Object[] keys) {
        int ret = 0;
        for (int i = 0; i < keys.length; i++) {
            Object key = keys[i];
            if (key != null) {
                ret *= 31;
                ret += System.identityHashCode(key);
            }
        }
        return ret;
    }

    private int computeHashCode(Object key1) {
        return key1 == null ? 0 : System.identityHashCode(key1);
    }

    private int computeHashCode(Object key1, Object key2) {
        int ret = computeHashCode(key1);
        if (key2 != null) ret = ret * 31 + System.identityHashCode(key2);
        return ret;
    }

    private int computeHashCode(Object key1, Object key2, Object key3) {
        int ret = computeHashCode(key1, key2);
        if (key3 != null) ret = ret * 31 + System.identityHashCode(key3);
        return ret;
    }

    private int computeHashCode(Object key1, Object key2, Object key3, Object key4) {
        int ret = computeHashCode(key1, key2, key3);
        if (key4 != null) ret = ret * 31 + System.identityHashCode(key4);
        return ret;
    }

    // -------- Resize --------

    private void checkUpCapacity() {
        if (size >= upThreshold) {
            int newCapacity = table.length * 2;
            if (newCapacity <= MAXIMUM_CAPACITY) {
                adjustCapacity(newCapacity);
            }
        }
    }

    private void checkDownCapacity() {
        if (size <= downThreshold) {
            int newCapacity = table.length / 2;
            int newDownThreshold = (int)(DEFAULT_REDUCE_FACTOR * newCapacity);
            while (size <= newDownThreshold && newCapacity > DEFAULT_CAPACITY) {
                newCapacity = newCapacity / 2;
                newDownThreshold = (int)(DEFAULT_REDUCE_FACTOR * newCapacity);
            }
            if (newCapacity >= DEFAULT_CAPACITY) {
                adjustCapacity(newCapacity);
            }
        }
    }

    private void adjustCapacity(int newCapacity) {
        // Atomic rehash + publish via a no-safepoint section in the VM.
        // Closes the window where chain entries lived only in the unpublished
        // WeakObjArrayKlass-typed staging table whose slots are scan-suppressed
        // during young GC; the old Java rehash could lose entries to a
        // mid-rehash GC, leaving from-space pointers that crashed mutators
        // and full-GC compaction.
        int newUp   = (int)(DEFAULT_LOAD_FACTOR   * newCapacity);
        int newDown = (int)(DEFAULT_REDUCE_FACTOR * newCapacity);
        adjustCapacity0(newCapacity, newUp, newDown);
    }

    private native void adjustCapacity0(int newCapacity, int newUpThreshold, int newDownThreshold);

    /** Bucket array allocated via WeakObjArrayKlass for VM-side GC suppression. */
    private static native IndexingTreeEntry[] allocateTable(int capacity);

    private native void init(int capacity);
}
