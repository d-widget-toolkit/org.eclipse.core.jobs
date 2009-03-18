/*******************************************************************************
 * Copyright (c) 2003, 2006 IBM Corporation and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Contributors:
 *     IBM Corporation - initial API and implementation
 * Port to the D programming language:
 *     Frank Benoit <benoit@tionex.de>
 *******************************************************************************/
module org.eclipse.core.internal.jobs.DeadlockDetector;

import java.lang.Thread;

import java.lang.all;
import java.util.ArrayList;
import java.util.Set;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.MultiStatus;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.ILock;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.internal.jobs.Deadlock;
import org.eclipse.core.internal.jobs.JobManager;

/**
 * Stores all the relationships between locks (rules are also considered locks),
 * and the threads that own them. All the relationships are stored in a 2D integer array.
 * The rows in the array are threads, while the columns are locks.
 * Two corresponding arrayLists store the actual threads and locks.
 * The index of a thread in the first arrayList is the index of the row in the graph.
 * The index of a lock in the second arrayList is the index of the column in the graph.
 * An entry greater than 0 in the graph is the number of times a thread in the entry's row
 * acquired the lock in the entry's column.
 * An entry of -1 means that the thread is waiting to acquire the lock.
 * An entry of 0 means that the thread and the lock have no relationship.
 *
 * The difference between rules and locks is that locks can be suspended, while
 * rules are implicit locks and as such cannot be suspended.
 * To resolve deadlock, the graph will first try to find a thread that only owns
 * locks. Failing that, it will find a thread in the deadlock that owns at least
 * one lock and suspend it.
 *
 * Deadlock can only occur among locks, or among locks in combination with rules.
 * Deadlock among rules only is impossible. Therefore, in any deadlock one can always
 * find a thread that owns at least one lock that can be suspended.
 *
 * The implementation of the graph assumes that a thread can only own 1 rule at
 * any one time. It can acquire that rule several times, but a thread cannot
 * acquire 2 non-conflicting rules at the same time.
 *
 * The implementation of the graph will sometimes also find and resolve bogus deadlocks.
 *      graph:              assuming this rule hierarchy:
 *         R2 R3 L1                     R1
 *      J1  1  0  0                    /  \
 *      J2  0  1 -1                   R2  R3
 *      J3 -1  0  1
 *
 * If in the above situation job4 decides to acquire rule1, then the graph will transform
 * to the following:
 *         R2 R3 R1 L1
 *      J1  1  0  1  0
 *      J2  1  1  1 -1
 *      J3 -1  0  0  1
 *      J4  0  0 -1  0
 *
 * and the graph will assume that job2 and job3 are deadlocked and suspend lock1 of job3.
 * The reason the deadlock is bogus is that the deadlock is unlikely to actually happen (the threads
 * are currently not deadlocked, but might deadlock later on when it is too late to detect it)
 * Therefore, in order to make sure that no deadlock is possible,
 * the deadlock will still be resolved at this point.
 */
class DeadlockDetector {
    private static int NO_STATE = 0;
    //state variables in the graph
    private static int WAITING_FOR_LOCK = -1;
    //empty matrix
    private static const int[][] EMPTY_MATRIX = null;
    //matrix of relationships between threads and locks
    private int[][] graph = EMPTY_MATRIX;
    //index is column in adjacency matrix for the lock
    private final ArrayList locks;
    //index is row in adjacency matrix for the thread
    private final ArrayList lockThreads;
    //whether the graph needs to be resized
    private bool resize = false;

    public this(){
        locks = new ArrayList();
        lockThreads = new ArrayList();
    }

    /**
     * Recursively check if any of the threads that prevent the current thread from running
     * are actually deadlocked with the current thread.
     * Add the threads that form deadlock to the deadlockedThreads list.
     */
    private bool addCycleThreads(ArrayList deadlockedThreads, Thread next) {
        //get the thread that block the given thread from running
        Thread[] blocking = blockingThreads(next);
        //if the thread is not blocked by other threads, then it is not part of a deadlock
        if (blocking.length is 0)
            return false;
        bool inCycle = false;
        for (int i = 0; i < blocking.length; i++) {
            //if we have already visited the given thread, then we found a cycle
            if (deadlockedThreads.contains(blocking[i])) {
                inCycle = true;
            } else {
                //otherwise, add the thread to our list and recurse deeper
                deadlockedThreads.add(blocking[i]);
                //if the thread is not part of a cycle, remove it from the list
                if (addCycleThreads(deadlockedThreads, blocking[i]))
                    inCycle = true;
                else
                    deadlockedThreads.remove(blocking[i]);
            }
        }
        return inCycle;
    }

    /**
     * Get the thread(s) that own the lock this thread is waiting for.
     */
    private Thread[] blockingThreads(Thread current) {
        //find the lock this thread is waiting for
        ISchedulingRule lock = cast(ISchedulingRule) getWaitingLock(current);
        return getThreadsOwningLock(lock);
    }

    /**
     * Check that the addition of a waiting thread did not produce deadlock.
     * If deadlock is detected return true, else return false.
     */
    private bool checkWaitCycles(int[] waitingThreads, int lockIndex) {
        /**
         * find the lock that this thread is waiting for
         * recursively check if this is a cycle (i.e. a thread waiting on itself)
         */
        for (int i = 0; i < graph.length; i++) {
            if (graph[i][lockIndex] > NO_STATE) {
                if (waitingThreads[i] > NO_STATE) {
                    return true;
                }
                //keep track that we already visited this thread
                waitingThreads[i]++;
                for (int j = 0; j < graph[i].length; j++) {
                    if (graph[i][j] is WAITING_FOR_LOCK) {
                        if (checkWaitCycles(waitingThreads, j))
                            return true;
                    }
                }
                //this thread is not involved in a cycle yet, so remove the visited flag
                waitingThreads[i]--;
            }
        }
        return false;
    }

    /**
     * Returns true IFF the matrix contains a row for the given thread.
     * (meaning the given thread either owns locks or is waiting for locks)
     */
    bool contains(Thread t) {
        return lockThreads.contains(t);
    }

    /**
     * A new rule was just added to the graph.
     * Find a rule it conflicts with and update the new rule with the number of times
     * it was acquired implicitly when threads acquired conflicting rule.
     */
    private void fillPresentEntries(ISchedulingRule newLock, int lockIndex) {
        //fill in the entries for the new rule from rules it conflicts with
        for (int j = 0; j < locks.size(); j++) {
            if ((j !is lockIndex) && (newLock.isConflicting(cast(ISchedulingRule) locks.get(j)))) {
                for (int i = 0; i < graph.length; i++) {
                    if ((graph[i][j] > NO_STATE) && (graph[i][lockIndex] is NO_STATE))
                        graph[i][lockIndex] = graph[i][j];
                }
            }
        }
        //now back fill the entries for rules the current rule conflicts with
        for (int j = 0; j < locks.size(); j++) {
            if ((j !is lockIndex) && (newLock.isConflicting(cast(ISchedulingRule) locks.get(j)))) {
                for (int i = 0; i < graph.length; i++) {
                    if ((graph[i][lockIndex] > NO_STATE) && (graph[i][j] is NO_STATE))
                        graph[i][j] = graph[i][lockIndex];
                }
            }
        }
    }

    /**
     * Returns all the locks owned by the given thread
     */
    private Object[] getOwnedLocks(Thread current) {
        ArrayList ownedLocks = new ArrayList(1);
        int index = indexOf(current, false);

        for (int j = 0; j < graph[index].length; j++) {
            if (graph[index][j] > NO_STATE)
                ownedLocks.add(locks.get(j));
        }
        if (ownedLocks.size() is 0)
            Assert.isLegal(false, "A thread with no locks is part of a deadlock."); //$NON-NLS-1$
        return ownedLocks.toArray();
    }

    /**
     * Returns an array of threads that form the deadlock (usually 2).
     */
    private Thread[] getThreadsInDeadlock(Thread cause) {
        ArrayList deadlockedThreads = new ArrayList(2);
        /**
         * if the thread that caused deadlock doesn't own any locks, then it is not part
         * of the deadlock (it just caused it because of a rule it tried to acquire)
         */
        if (ownsLocks(cause))
            deadlockedThreads.add(cause);
        addCycleThreads(deadlockedThreads, cause);
        return arraycast!(Thread)( deadlockedThreads.toArray());
    }

    /**
     * Returns the thread(s) that own the given lock.
     */
    private Thread[] getThreadsOwningLock(ISchedulingRule rule) {
        if (rule is null)
            return new Thread[0];
        int lockIndex = indexOf(rule, false);
        ArrayList blocking = new ArrayList(1);
        for (int i = 0; i < graph.length; i++) {
            if (graph[i][lockIndex] > NO_STATE)
                blocking.add(lockThreads.get(i));
        }
        if ((blocking.size() is 0) && (JobManager.DEBUG_LOCKS))
            getDwtLogger.info( __FILE__, __LINE__, "Lock {} is involved in deadlock but is not owned by any thread.", rule ); //$NON-NLS-1$ //$NON-NLS-2$
        if ((blocking.size() > 1) && (cast(ILock)rule ) && (JobManager.DEBUG_LOCKS))
            getDwtLogger.info( __FILE__, __LINE__, "Lock {} is owned by more than 1 thread, but it is not a rule.", rule ); //$NON-NLS-1$ //$NON-NLS-2$
        return arraycast!(Thread)( blocking.toArray());
    }

    /**
     * Returns the lock the given thread is waiting for.
     */
    private Object getWaitingLock(Thread current) {
        int index = indexOf(current, false);
        //find the lock that this thread is waiting for
        for (int j = 0; j < graph[index].length; j++) {
            if (graph[index][j] is WAITING_FOR_LOCK)
                return locks.get(j);
        }
        //it can happen that a thread is not waiting for any lock (it is not really part of the deadlock)
        return null;
    }

    /**
     * Returns the index of the given lock in the lock array. If the lock is
     * not present in the array, it is added to the end.
     */
    private int indexOf(ISchedulingRule lock, bool add) {
        int index = locks.indexOf(cast(Object)lock);
        if ((index < 0) && add) {
            locks.add(cast(Object)lock);
            resize = true;
            index = locks.size() - 1;
        }
        return index;
    }

    /**
     * Returns the index of the given thread in the thread array. If the thread
     * is not present in the array, it is added to the end.
     */
    private int indexOf(Thread owner, bool add) {
        int index = lockThreads.indexOf(owner);
        if ((index < 0) && add) {
            lockThreads.add(owner);
            resize = true;
            index = lockThreads.size() - 1;
        }
        return index;
    }

    /**
     * Returns true IFF the adjacency matrix is empty.
     */
    bool isEmpty() {
        return (locks.size() is 0) && (lockThreads.size() is 0) && (graph.length is 0);
    }

    /**
     * The given lock was acquired by the given thread.
     */
    void lockAcquired(Thread owner, ISchedulingRule lock) {
        int lockIndex = indexOf(lock, true);
        int threadIndex = indexOf(owner, true);
        if (resize)
            resizeGraph();
        if (graph[threadIndex][lockIndex] is WAITING_FOR_LOCK)
            graph[threadIndex][lockIndex] = NO_STATE;
        /**
         * acquire all locks that conflict with the given lock
         * or conflict with a lock the given lock will acquire implicitly
         * (locks are acquired implicitly when a conflicting lock is acquired)
         */
        ArrayList conflicting = new ArrayList(1);
        //only need two passes through all the locks to pick up all conflicting rules
        int NUM_PASSES = 2;
        conflicting.add(cast(Object)lock);
        graph[threadIndex][lockIndex]++;
        for (int i = 0; i < NUM_PASSES; i++) {
            for (int k = 0; k < conflicting.size(); k++) {
                ISchedulingRule current = cast(ISchedulingRule) conflicting.get(k);
                for (int j = 0; j < locks.size(); j++) {
                    ISchedulingRule possible = cast(ISchedulingRule) locks.get(j);
                    if (current.isConflicting(possible) && !conflicting.contains(cast(Object)possible)) {
                        conflicting.add(cast(Object)possible);
                        graph[threadIndex][j]++;
                    }
                }
            }
        }
    }

    /**
     * The given lock was released by the given thread. Update the graph.
     */
    void lockReleased(Thread owner, ISchedulingRule lock) {
        int lockIndex = indexOf(lock, false);
        int threadIndex = indexOf(owner, false);
        //make sure the lock and thread exist in the graph
        if (threadIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "[lockReleased] Lock {} was already released by thread {}", lock, owner.getName()); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        if (lockIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "[lockReleased] Thread {} already released lock {}", owner.getName(), lock); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        //if this lock was suspended, set it to NO_STATE
        if ((cast(ILock)lock ) && (graph[threadIndex][lockIndex] is WAITING_FOR_LOCK)) {
            graph[threadIndex][lockIndex] = NO_STATE;
            return;
        }
        //release all locks that conflict with the given lock
        //or release all rules that are owned by the given thread, if we are releasing a rule
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if ((lock.isConflicting(cast(ISchedulingRule) locks.get(j))) || (!(cast(ILock)lock ) && !(cast(ILock)locks.get(j)) && (graph[threadIndex][j] > NO_STATE))) {
                if (graph[threadIndex][j] is NO_STATE) {
                    if (JobManager.DEBUG_LOCKS)
                        getDwtLogger.info( __FILE__, __LINE__, "[lockReleased] More releases than acquires for thread {} and lock {}", owner.getName(), lock); //$NON-NLS-1$ //$NON-NLS-2$
                } else {
                    graph[threadIndex][j]--;
                }
            }
        }
        //if this thread just released the given lock, try to simplify the graph
        if (graph[threadIndex][lockIndex] is NO_STATE)
            reduceGraph(threadIndex, lock);
    }

    /**
     * The given scheduling rule is no longer used because the job that invoked it is done.
     * Release this rule regardless of how many times it was acquired.
     */
    void lockReleasedCompletely(Thread owner, ISchedulingRule rule) {
        int ruleIndex = indexOf(rule, false);
        int threadIndex = indexOf(owner, false);
        //need to make sure that the given thread and rule were not already removed from the graph
        if (threadIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "[lockReleasedCompletely] Lock {} was already released by thread {}", rule, owner.getName()); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        if (ruleIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "[lockReleasedCompletely] Thread {} already released lock {}", owner.getName(), rule); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        /**
         * set all rules that are owned by the given thread to NO_STATE
         * (not just rules that conflict with the rule we are releasing)
         * if we are releasing a lock, then only update the one entry for the lock
         */
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if (!(cast(ILock)locks.get(j) ) && (graph[threadIndex][j] > NO_STATE))
                graph[threadIndex][j] = NO_STATE;
        }
        reduceGraph(threadIndex, rule);
    }

    /**
     * The given thread could not get the given lock and is waiting for it.
     * Update the graph.
     */
    Deadlock lockWaitStart(Thread client, ISchedulingRule lock) {
        setToWait(client, lock, false);
        int lockIndex = indexOf(lock, false);
        int[] temp = new int[lockThreads.size()];
        //check if the addition of the waiting thread caused deadlock
        if (!checkWaitCycles(temp, lockIndex))
            return null;
        //there is a deadlock in the graph
        Thread[] threads = getThreadsInDeadlock(client);
        Thread candidate = resolutionCandidate(threads);
        ISchedulingRule[] locksToSuspend = realLocksForThread(candidate);
        Deadlock deadlock = new Deadlock(threads, locksToSuspend, candidate);
        //find a thread whose locks can be suspended to resolve the deadlock
        if (JobManager.DEBUG_LOCKS)
            reportDeadlock(deadlock);
        if (JobManager.DEBUG_DEADLOCK)
            throw new IllegalStateException(Format("Deadlock detected. Caused by thread {}.", client.getName())); //$NON-NLS-1$
        // Update the graph to indicate that the locks will now be suspended.
        // To indicate that the lock will be suspended, we set the thread to wait for the lock.
        // When the lock is forced to be released, the entry will be cleared.
        for (int i = 0; i < locksToSuspend.length; i++)
            setToWait(deadlock.getCandidate(), locksToSuspend[i], true);
        return deadlock;
    }

    /**
     * The given thread has stopped waiting for the given lock.
     * Update the graph.
     */
    void lockWaitStop(Thread owner, ISchedulingRule lock) {
        int lockIndex = indexOf(lock, false);
        int threadIndex = indexOf(owner, false);
        //make sure the thread and lock exist in the graph
        if (threadIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "Thread {} was already removed.", owner.getName() ); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        if (lockIndex < 0) {
            if (JobManager.DEBUG_LOCKS)
                getDwtLogger.info( __FILE__, __LINE__, "Lock {} was already removed.", lock ); //$NON-NLS-1$ //$NON-NLS-2$
            return;
        }
        if (graph[threadIndex][lockIndex] !is WAITING_FOR_LOCK)
            Assert.isTrue(false, Format("Thread {} was not waiting for lock {} so it could not time out.", owner.getName(), (cast(Object)lock).toString())); //$NON-NLS-1$ //$NON-NLS-2$ //$NON-NLS-3$
        graph[threadIndex][lockIndex] = NO_STATE;
        reduceGraph(threadIndex, lock);
    }

    /**
     * Returns true IFF the given thread owns a single lock
     */
    private bool ownsLocks(Thread cause) {
        int threadIndex = indexOf(cause, false);
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if (graph[threadIndex][j] > NO_STATE)
                return true;
        }
        return false;
    }

    /**
     * Returns true IFF the given thread owns a single real lock.
     * A real lock is a lock that can be suspended.
     */
    private bool ownsRealLocks(Thread owner) {
        int threadIndex = indexOf(owner, false);
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if (graph[threadIndex][j] > NO_STATE) {
                Object lock = locks.get(j);
                if (cast(ILock)lock )
                    return true;
            }
        }
        return false;
    }

    /**
     * Return true IFF this thread owns rule locks (i.e. implicit locks which
     * cannot be suspended)
     */
    private bool ownsRuleLocks(Thread owner) {
        int threadIndex = indexOf(owner, false);
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if (graph[threadIndex][j] > NO_STATE) {
                Object lock = locks.get(j);
                if (!(cast(ILock)lock ))
                    return true;
            }
        }
        return false;
    }

    /**
     * Returns an array of real locks that are owned by the given thread.
     * Real locks are locks that implement the ILock interface and can be suspended.
     */
    private ISchedulingRule[] realLocksForThread(Thread owner) {
        int threadIndex = indexOf(owner, false);
        ArrayList ownedLocks = new ArrayList(1);
        for (int j = 0; j < graph[threadIndex].length; j++) {
            if ((graph[threadIndex][j] > NO_STATE) && (cast(ILock)locks.get(j) ))
                ownedLocks.add(locks.get(j));
        }
        if (ownedLocks.size() is 0)
            Assert.isLegal(false, "A thread with no real locks was chosen to resolve deadlock."); //$NON-NLS-1$
        return arraycast!(ISchedulingRule)( ownedLocks.toArray());
    }

    /**
     * The matrix has been simplified. Check if any unnecessary rows or columns
     * can be removed.
     */
    private void reduceGraph(int row, ISchedulingRule lock) {
        int numLocks = locks.size();
        bool[] emptyColumns = new bool[numLocks];

        /**
         * find all columns that could possibly be empty
         * (consist of locks which conflict with the given lock, or of locks which are rules)
         */
        for (int j = 0; j < numLocks; j++) {
            if ((lock.isConflicting(cast(ISchedulingRule) locks.get(j))) || !(cast(ILock)locks.get(j)))
                emptyColumns[j] = true;
        }

        bool rowEmpty = true;
        int numEmpty = 0;
        //check if the given row is empty
        for (int j = 0; j < graph[row].length; j++) {
            if (graph[row][j] !is NO_STATE) {
                rowEmpty = false;
                break;
            }
        }
        /**
         * Check if the possibly empty columns are actually empty.
         * If a column is actually empty, remove the corresponding lock from the list of locks
         * Start at the last column so that when locks are removed from the list,
         * the index of the remaining locks is unchanged. Store the number of empty columns.
         */
        for (int j = emptyColumns.length - 1; j >= 0; j--) {
            for (int i = 0; i < graph.length; i++) {
                if (emptyColumns[j] && (graph[i][j] !is NO_STATE)) {
                    emptyColumns[j] = false;
                    break;
                }
            }
            if (emptyColumns[j]) {
                locks.remove(j);
                numEmpty++;
            }
        }
        //if no columns or rows are empty, return right away
        if ((numEmpty is 0) && (!rowEmpty))
            return;

        if (rowEmpty)
            lockThreads.remove(row);

        //new graph (the list of locks and the list of threads are already updated)
        final int numThreads = lockThreads.size();
        numLocks = locks.size();
        //optimize empty graph case
        if (numThreads is 0 && numLocks is 0) {
            graph = EMPTY_MATRIX;
            return;
        }
        int[][] tempGraph = new int[][](numThreads,numLocks);

        //the number of rows we need to skip to get the correct entry from the old graph
        int numRowsSkipped = 0;
        for (int i = 0; i < graph.length - numRowsSkipped; i++) {
            if ((i is row) && rowEmpty) {
                numRowsSkipped++;
                //check if we need to skip the last row
                if (i >= graph.length - numRowsSkipped)
                    break;
            }
            //the number of columns we need to skip to get the correct entry from the old graph
            //needs to be reset for every new row
            int numColsSkipped = 0;
            for (int j = 0; j < graph[i].length - numColsSkipped; j++) {
                while (emptyColumns[j + numColsSkipped]) {
                    numColsSkipped++;
                    //check if we need to skip the last column
                    if (j >= graph[i].length - numColsSkipped)
                        break;
                }
                //need to break out of the outer loop
                if (j >= graph[i].length - numColsSkipped)
                    break;
                tempGraph[i][j] = graph[i + numRowsSkipped][j + numColsSkipped];
            }
        }
        graph = tempGraph;
        Assert.isTrue(numThreads is graph.length, "Rows and threads don't match."); //$NON-NLS-1$
        Assert.isTrue(numLocks is ((graph.length > 0) ? graph[0].length : 0), "Columns and locks don't match."); //$NON-NLS-1$
    }

    /**
     * Adds a 'deadlock detected' message to the log with a stack trace.
     */
    private void reportDeadlock(Deadlock deadlock) {
        String msg = "Deadlock detected. All locks owned by thread " ~ deadlock.getCandidate().getName() ~ " will be suspended."; //$NON-NLS-1$ //$NON-NLS-2$
        MultiStatus main = new MultiStatus(JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, msg, new IllegalStateException());
        Thread[] threads = deadlock.getThreads();
        for (int i = 0; i < threads.length; i++) {
            Object[] ownedLocks = getOwnedLocks(threads[i]);
            Object waitLock = getWaitingLock(threads[i]);
            StringBuffer buf = new StringBuffer("Thread "); //$NON-NLS-1$
            buf.append(threads[i].getName());
            buf.append(" has locks: "); //$NON-NLS-1$
            for (int j = 0; j < ownedLocks.length; j++) {
                buf.append(Format("{}",ownedLocks[j]));
                buf.append((j < ownedLocks.length - 1) ? ", " : " "); //$NON-NLS-1$ //$NON-NLS-2$
            }
            buf.append("and is waiting for lock "); //$NON-NLS-1$
            buf.append(Format("{}",waitLock));
            Status child = new Status(IStatus.ERROR, JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, buf.toString(), null);
            main.add(child);
        }
        RuntimeLog.log(main);
    }

    /**
     * The number of threads/locks in the graph has changed. Update the
     * underlying matrix.
     */
    private void resizeGraph() {
        // a new row and/or a new column was added to the graph.
        // since new rows/columns are always added to the end, just transfer
        // old entries to the new graph, with the same indices.
        final int newRows = lockThreads.size();
        final int newCols = locks.size();
        //optimize 0x0 and 1x1 matrices
        if (newRows is 0 && newCols is 0) {
            graph = EMPTY_MATRIX;
            return;
        }
        int[][] tempGraph = new int[][](newRows,newCols);
        for (int i = 0; i < graph.length; i++)
            System.arraycopy(graph[i], 0, tempGraph[i], 0, graph[i].length);
        graph = tempGraph;
        resize = false;
    }

    /**
     * Get the thread whose locks can be suspended. (i.e. all locks it owns are
     * actual locks and not rules). Return the first thread in the array by default.
     */
    private Thread resolutionCandidate(Thread[] candidates) {
        //first look for a candidate that has no scheduling rules
        for (int i = 0; i < candidates.length; i++) {
            if (!ownsRuleLocks(candidates[i]))
                return candidates[i];
        }
        //next look for any candidate with a real lock (a lock that can be suspended)
        for (int i = 0; i < candidates.length; i++) {
            if (ownsRealLocks(candidates[i]))
                return candidates[i];
        }
        //unnecessary, return the first entry in the array by default
        return candidates[0];
    }

    /**
     * The given thread is waiting for the given lock. Update the graph.
     */
    private void setToWait(Thread owner, ISchedulingRule lock, bool suspend) {
        bool needTransfer = false;
        /**
         * if we are adding an entry where a thread is waiting on a scheduling rule,
         * then we need to transfer all positive entries for a conflicting rule to the
         * newly added rule in order to synchronize the graph.
         */
        if (!suspend && !(cast(ILock)lock))
            needTransfer = true;
        int lockIndex = indexOf(lock, !suspend);
        int threadIndex = indexOf(owner, !suspend);
        if (resize)
            resizeGraph();

        graph[threadIndex][lockIndex] = WAITING_FOR_LOCK;
        if (needTransfer)
            fillPresentEntries(lock, lockIndex);
    }

    /**
     * Prints out the current matrix to standard output.
     * Only used for debugging.
     */
    public String toDebugString() {
        StringBuffer sb = new StringBuffer();
        sb.append(" :: \n"); //$NON-NLS-1$
        for (int j = 0; j < locks.size(); j++) {
            sb.append(" ");
            sb.append( locks.get(j).toString );
            sb.append(",");
        }
        sb.append("\n");
        for (int i = 0; i < graph.length; i++) {
            sb.append(" ");
            sb.append( (cast(Thread) lockThreads.get(i)).getName() );
            sb.append(" : ");
            for (int j = 0; j < graph[i].length; j++) {
                sb.append(" ");
                sb.append(Integer.toString(graph[i][j])); //$NON-NLS-1$
                sb.append(",");
            }
            sb.append("\n");
        }
        sb.append("-------\n"); //$NON-NLS-1$
        return sb.toString();
    }
}
