/*
 * @test TestIndexingTreeConcurrentInit
 * @summary Verify that concurrent first inserts publish only one native IndexingTree table.
 * @modules java.base/java.lang.rv
 * @run main/othervm --add-opens java.base/java.lang.rv=ALL-UNNAMED -Xmx512m -Xms512m
 *      TestIndexingTreeConcurrentInit
 */

import java.lang.reflect.Field;
import java.lang.rv.IndexingTree;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.atomic.AtomicReference;

public class TestIndexingTreeConcurrentInit {
    private static final int CAPACITY = 1 << 16;
    private static final int THREADS = 32;
    private static final int TRIALS = 300;

    private static final Field CAPACITY_FIELD;
    private static final Field UP_THRESHOLD_FIELD;
    private static final Field DOWN_THRESHOLD_FIELD;

    static {
        try {
            CAPACITY_FIELD = IndexingTree.class.getDeclaredField("capacity");
            UP_THRESHOLD_FIELD = IndexingTree.class.getDeclaredField("upThreshold");
            DOWN_THRESHOLD_FIELD = IndexingTree.class.getDeclaredField("downThreshold");
            CAPACITY_FIELD.setAccessible(true);
            UP_THRESHOLD_FIELD.setAccessible(true);
            DOWN_THRESHOLD_FIELD.setAccessible(true);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    public static void main(String[] args) throws Exception {
        for (int trial = 0; trial < TRIALS; trial++) {
            runTrial(trial);
        }
        System.out.println("PASS: " + TRIALS + " concurrent lazy-init trials");
    }

    private static void runTrial(int trial) throws Exception {
        IndexingTree tree = new IndexingTree();
        widenInitialTable(tree);

        Object[] keys = distinctBucketKeys(THREADS);
        Object[] values = new Object[THREADS];
        CyclicBarrier start = new CyclicBarrier(THREADS);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread[] threads = new Thread[THREADS];

        for (int i = 0; i < THREADS; i++) {
            final int index = i;
            values[index] = new Object();
            threads[index] = new Thread(() -> {
                try {
                    start.await();
                    tree.put(values[index], keys[index]);
                } catch (Throwable t) {
                    failure.compareAndSet(null, t);
                }
            }, "indexing-tree-init-" + trial + "-" + index);
        }

        for (Thread thread : threads) {
            thread.start();
        }
        for (Thread thread : threads) {
            thread.join();
        }

        Throwable thrown = failure.get();
        if (thrown != null) {
            throw new RuntimeException("worker failed in trial " + trial, thrown);
        }

        for (int i = 0; i < THREADS; i++) {
            Object actual = tree.get1(keys[i]);
            if (actual != values[i]) {
                throw new RuntimeException("lost entry in trial " + trial + ", index " + i);
            }
        }
    }

    private static void widenInitialTable(IndexingTree tree) throws Exception {
        CAPACITY_FIELD.setInt(tree, CAPACITY);
        UP_THRESHOLD_FIELD.setInt(tree, CAPACITY);
        DOWN_THRESHOLD_FIELD.setInt(tree, 0);
    }

    private static Object[] distinctBucketKeys(int count) {
        boolean[] used = new boolean[CAPACITY];
        Object[] keys = new Object[count];
        int size = 0;
        while (size < count) {
            Object key = new Object();
            int bucket = System.identityHashCode(key) & (CAPACITY - 1);
            if (!used[bucket]) {
                used[bucket] = true;
                keys[size++] = key;
            }
        }
        return keys;
    }
}
