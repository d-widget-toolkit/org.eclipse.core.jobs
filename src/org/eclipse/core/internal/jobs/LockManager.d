/*******************************************************************************
 * Copyright (c) 2003, 2006 IBM Corporation and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Contributors:
 *     IBM - Initial API and implementation
 * Port to the D programming language:
 *     Frank Benoit <benoit@tionex.de>
 *******************************************************************************/
module org.eclipse.core.internal.jobs.LockManager;

import java.lang.Thread;
import java.lang.all;
import java.util.Stack;
import java.util.HashMap;
import java.util.Set;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.MultiStatus;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.runtime.jobs.LockListener;

import org.eclipse.core.internal.jobs.OrderedLock;
import org.eclipse.core.internal.jobs.DeadlockDetector;
import org.eclipse.core.internal.jobs.Deadlock;
import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.Worker;

/**
 * Stores the only reference to the graph that contains all the known
 * relationships between locks, rules, and the threads that own them.
 * Synchronizes all access to the graph on the only instance that exists in this class.
 *
 * Also stores the state of suspended locks so that they can be re-acquired with
 * the proper lock depth.
 */
public class LockManager {
    /**
     * This class captures the state of suspended locks.
     * Locks are suspended if deadlock is detected.
     */
    private static class LockState {
        private int depth;
        private OrderedLock lock;

        /**
         * Suspends ownership of the given lock, and returns the saved state.
         */
        protected static LockState suspend(OrderedLock lock) {
            LockState state = new LockState();
            state.lock = lock;
            state.depth = lock.forceRelease_package();
            return state;
        }

        /**
         * Re-acquires a suspended lock and reverts to the correct lock depth.
         */
        public void resume() {
            //spin until the lock is successfully acquired
            //NOTE: spinning here allows the UI thread to service pending syncExecs
            //if the UI thread is waiting to acquire a lock.
            while (true) {
                try {
                    if (lock.acquire(Long.MAX_VALUE))
                        break;
                } catch (InterruptedException e) {
                    //ignore and loop
                }
            }
            lock.setDepth_package(depth);
        }
    }

    //the lock listener for this lock manager
    protected LockListener lockListener;
    /*
     * The internal data structure that stores all the relationships
     * between the locks (or rules) and the threads that own them.
     */
    private DeadlockDetector locks;
    /*
     * Stores thread - stack pairs where every entry in the stack is an array
     * of locks that were suspended while the thread was acquiring more locks
     * (a stack is needed because when a thread tries to re-aquire suspended locks,
     * it can cause deadlock, and some locks it owns can be suspended again)
     */
    private HashMap suspendedLocks;

    public this() {
//         super();
        locks = new DeadlockDetector();
        suspendedLocks = new HashMap();
    }

    /* (non-Javadoc)
     * Method declared on LockListener
     */
    public void aboutToRelease() {
        if (lockListener is null)
            return;
        try {
            lockListener.aboutToRelease();
        } catch (Exception e) {
            handleException(e);
//         } catch (LinkageError e) {
//             handleException(e);
        }
    }

    /* (non-Javadoc)
     * Method declared on LockListener
     */
    public bool aboutToWait(Thread lockOwner) {
        if (lockListener is null)
            return false;
        try {
            return lockListener.aboutToWait(lockOwner);
        } catch (Exception e) {
            handleException(e);
//         } catch (LinkageError e) {
//             handleException(e);
        }
        return false;
    }

    /**
     * This thread has just acquired a lock.  Update graph.
     */
    void addLockThread(Thread thread, ISchedulingRule lock) {
        if (locks is null)
            return;
        try {
            synchronized (locks) {
                locks.lockAcquired(thread, lock);
            }
        } catch (Exception e) {
            handleInternalError(e);
        }
    }

    /**
     * This thread has just been refused a lock.  Update graph and check for deadlock.
     */
    void addLockWaitThread(Thread thread, ISchedulingRule lock) {
        if (locks is null)
            return;
        try {
            Deadlock found = null;
            synchronized (locks) {
                found = locks.lockWaitStart(thread, lock);
            }
            if (found is null)
                return;
            // if deadlock was detected, the found variable will contain all the information about it,
            // including which locks to suspend for which thread to resolve the deadlock.
            ISchedulingRule[] toSuspend = found.getLocks();
            LockState[] suspended = new LockState[toSuspend.length];
            for (int i = 0; i < toSuspend.length; i++)
                suspended[i] = LockState.suspend(cast(OrderedLock) toSuspend[i]);
            synchronized (suspendedLocks) {
                Stack prevLocks = cast(Stack) suspendedLocks.get(found.getCandidate());
                if (prevLocks is null)
                    prevLocks = new Stack();
                prevLocks.push(new ArrayWrapperObject(suspended));
                suspendedLocks.put(found.getCandidate(), prevLocks);
            }
        } catch (Exception e) {
            handleInternalError(e);
        }
    }

    /**
     * Handles exceptions that occur while calling third party code from within the
     * LockManager. This is essentially an in-lined version of Platform.run(ISafeRunnable)
     */
    private static void handleException(Exception e) {
        IStatus status;
        if (cast(CoreException)e ) {
            //logged message should not be translated
            status = new MultiStatus(JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, "LockManager.handleException", e); //$NON-NLS-1$
            (cast(MultiStatus) status).merge((cast(CoreException) e).getStatus());
        } else {
            status = new Status(IStatus.ERROR, JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, "LockManager.handleException", e); //$NON-NLS-1$
        }
        RuntimeLog.log(status);
    }

    /**
     * There was an internal error in the deadlock detection code.  Shut the entire
     * thing down to prevent further errors.  Recovery is too complex as it
     * requires freezing all threads and inferring the present lock state.
     */
    private void handleInternalError(Exception t) {
        try {
            handleException(t);
            handleException(new Exception(locks.toDebugString()));
        } catch (Exception e2) {
            //ignore failure to log or to create the debug string
        }
        //discard the deadlock detector for good
        locks = null;
    }

    /**
     * Returns true IFF the underlying graph is empty.
     * For debugging purposes only.
     */
    public bool isEmpty() {
        return locks.isEmpty();
    }

    /**
     * Returns true IFF this thread either owns, or is waiting for, any locks or rules.
     */
    public bool isLockOwner() {
        //all job threads have to be treated as lock owners because UI thread
        //may try to join a job
        Thread current = Thread.currentThread();
        if (cast(Worker)current )
            return true;
        if (locks is null)
            return false;
        synchronized (locks) {
            return locks.contains(Thread.currentThread());
        }
    }

    /**
     * Creates and returns a new lock.
     */
    public synchronized OrderedLock newLock() {
        return new OrderedLock(this);
    }

    /**
     * Releases all the acquires that were called on the given rule. Needs to be called only once.
     */
    void removeLockCompletely(Thread thread, ISchedulingRule rule) {
        if (locks is null)
            return;
        try {
            synchronized (locks) {
                locks.lockReleasedCompletely(thread, rule);
            }
        } catch (Exception e) {
            handleInternalError(e);
        }
    }

    /**
     * This thread has just released a lock.  Update graph.
     */
    void removeLockThread(Thread thread, ISchedulingRule lock) {
        try {
            synchronized (locks) {
                locks.lockReleased(thread, lock);
            }
        } catch (Exception e) {
            handleInternalError(e);
        }
    }

    /**
     * This thread has just stopped waiting for a lock. Update graph.
     */
    void removeLockWaitThread(Thread thread, ISchedulingRule lock) {
        try {
            synchronized (locks) {
                locks.lockWaitStop(thread, lock);
            }
        } catch (Exception e) {
            handleInternalError(e);
        }
    }

    /**
     * Resumes all the locks that were suspended while this thread was waiting to acquire another lock.
     */
    void resumeSuspendedLocks(Thread owner) {
        LockState[] toResume;
        synchronized (suspendedLocks) {
            Stack prevLocks = cast(Stack) suspendedLocks.get(owner);
            if (prevLocks is null)
                return;
            toResume = arrayFromObject!(LockState)( prevLocks.pop() );
            if (prevLocks.empty())
                suspendedLocks.remove(owner);
        }
        for (int i = 0; i < toResume.length; i++)
            toResume[i].resume();
    }

    public void setLockListener(LockListener listener) {
        this.lockListener = listener;
    }
}
