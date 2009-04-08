/*******************************************************************************
 * Copyright (c) 2003, 2007 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.WorkerPool;

import java.lang.Thread;
import tango.core.sync.Mutex;
import tango.core.sync.Condition;
import java.lang.all;
import java.util.Set;

import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.Worker;

import org.eclipse.core.internal.jobs.InternalJob;
import org.eclipse.core.internal.jobs.ThreadJob;

/**
 * Maintains a pool of worker threads. Threads are constructed lazily as
 * required, and are eventually discarded if not in use for awhile. This class
 * maintains the thread creation/destruction policies for the job manager.
 *
 * Implementation note: all the data structures of this class are protected
 * by the instance's object monitor.  To avoid deadlock with third party code,
 * this lock is never held when calling methods outside this class that may in
 * turn use locks.
 */
class WorkerPool {

    protected Mutex mutex;
    protected Condition condition;


    /**
     * Threads not used by their best before timestamp are destroyed.
     */
    private static const int BEST_BEFORE = 60000;
    /**
     * There will always be at least MIN_THREADS workers in the pool.
     */
    private static const int MIN_THREADS = 1;
    /**
     * Use the busy thread count to avoid starting new threads when a living
     * thread is just doing house cleaning (notifying listeners, etc).
     */
    private int busyThreads = 0;

    /**
     * The default context class loader to use when creating worker threads.
     */
//     protected const ClassLoader defaultContextLoader;

    /**
     * Records whether new worker threads should be daemon threads.
     */
    private bool isDaemon = false;

    private JobManager manager;
    /**
     * The number of workers in the threads array
     */
    private int numThreads = 0;
    /**
     * The number of threads that are currently sleeping
     */
    private int sleepingThreads = 0;
    /**
     * The living set of workers in this pool.
     */
    private Worker[] threads;

    /*protected package*/ this(JobManager manager) {
        threads = new Worker[10];
        this.manager = manager;
        mutex = new Mutex;
        condition = new Condition(mutex);
//         this.defaultContextLoader = Thread.currentThread().getContextClassLoader();
    }

    /**
     * Adds a worker to the list of workers.
     */
    private void add(Worker worker) {
        synchronized(mutex){
            int size = threads.length;
            if (numThreads + 1 > size) {
                Worker[] newThreads = new Worker[2 * size];
                System.arraycopy(threads, 0, newThreads, 0, size);
                threads = newThreads;
            }
            threads[numThreads++] = worker;
        }
    }

    private void decrementBusyThreads() {
        synchronized(mutex){
            //impossible to have less than zero busy threads
            if (--busyThreads < 0) {
                if (JobManager.DEBUG)
                    Assert.isTrue(false, Integer.toString(busyThreads));
                busyThreads = 0;
            }
        }
    }

    /**
     * Signals the end of a job.  Note that this method can be called under
     * OutOfMemoryError conditions and thus must be paranoid about allocating objects.
     */
    protected void endJob(InternalJob job, IStatus result) {
        decrementBusyThreads();
        //need to end rule in graph before ending job so that 2 threads
        //do not become the owners of the same rule in the graph
        if ((job.getRule_package() !is null) && !(cast(ThreadJob)job )) {
            //remove any locks this thread may be owning on that rule
            manager.getLockManager().removeLockCompletely(Thread.currentThread(), job.getRule_package());
        }
        manager.endJob_package(job, result, true);
        //ensure this thread no longer owns any scheduling rules
        manager.implicitJobs.endJob(job);
    }
    package void endJob_package(InternalJob job, IStatus result) {
        endJob(job, result);
    }

    /**
     * Signals the death of a worker thread.  Note that this method can be called under
     * OutOfMemoryError conditions and thus must be paranoid about allocating objects.
     */
    protected void endWorker(Worker worker) {
        synchronized(mutex){
            if (remove(worker) && JobManager.DEBUG)
                JobManager.debug_(Format("worker removed from pool: {}", worker)); //$NON-NLS-1$
        }
    }
    package void endWorker_package(Worker worker) {
        endWorker(worker);
    }

    private void incrementBusyThreads() {
        synchronized(mutex){
            //impossible to have more busy threads than there are threads
            if (++busyThreads > numThreads) {
                if (JobManager.DEBUG)
                    Assert.isTrue(false, Format( "{},{}", busyThreads, numThreads));
                busyThreads = numThreads;
            }
        }
    }

    /**
     * Notification that a job has been added to the queue. Wake a worker,
     * creating a new worker if necessary. The provided job may be null.
     */
    /*protected package*/ void jobQueued() {
        synchronized(mutex){
            //if there is a sleeping thread, wake it up
            if (sleepingThreads > 0) {
                condition.notify();
                return;
            }
            //create a thread if all threads are busy
            if (busyThreads >= numThreads) {
                Worker worker = new Worker(this);
                worker.setDaemon(isDaemon);
                add(worker);
                if (JobManager.DEBUG)
                    JobManager.debug_(Format("worker added to pool: {}", worker)); //$NON-NLS-1$
                worker.start();
                return;
            }
        }
    }

    /**
     * Remove a worker thread from our list.
     * @return true if a worker was removed, and false otherwise.
     */
    private bool remove(Worker worker) {
        synchronized(mutex){
            for (int i = 0; i < threads.length; i++) {
                if (threads[i] is worker) {
                    System.arraycopy(threads, i + 1, threads, i, numThreads - i - 1);
                    threads[--numThreads] = null;
                    return true;
                }
            }
            return false;
        }
    }

    /**
     * Sets whether threads created in the worker pool should be daemon threads.
     */
    void setDaemon(bool value) {
        this.isDaemon = value;
    }

    protected void shutdown() {
        synchronized(mutex){
            condition.notifyAll();
        }
    }
    package void shutdown_package() {
        shutdown();
    }

    /**
     * Sleep for the given duration or until woken.
     */
    private void sleep(long duration) {
        synchronized(mutex){
            sleepingThreads++;
            busyThreads--;
            if (JobManager.DEBUG)
                JobManager.debug_(Format("worker sleeping for: {}ms", duration)); //$NON-NLS-1$ //$NON-NLS-2$
            try {
                condition.wait(duration/1000.0f);
            } catch (InterruptedException e) {
                if (JobManager.DEBUG)
                    JobManager.debug_("worker interrupted while waiting... :-|"); //$NON-NLS-1$
            } finally {
                sleepingThreads--;
                busyThreads++;
            }
        }
    }

    /**
     * Returns a new job to run. Returns null if the thread should die.
     */
    protected InternalJob startJob(Worker worker) {
        //if we're above capacity, kill the thread
        synchronized (mutex) {
            if (!manager.isActive_package()) {
                //must remove the worker immediately to prevent all threads from expiring
                endWorker(worker);
                return null;
            }
            //set the thread to be busy now in case of reentrant scheduling
            incrementBusyThreads();
        }
        Job job = null;
        try {
            job = manager.startJob_package();
            //spin until a job is found or until we have been idle for too long
            long idleStart = System.currentTimeMillis();
            while (manager.isActive_package() && job is null) {
                long hint = manager.sleepHint_package();
                if (hint > 0)
                    sleep(Math.min(hint, BEST_BEFORE));
                job = manager.startJob_package();
                //if we were already idle, and there are still no new jobs, then
                // the thread can expire
                synchronized (mutex) {
                    if (job is null && (System.currentTimeMillis() - idleStart > BEST_BEFORE) && (numThreads - busyThreads) > MIN_THREADS) {
                        //must remove the worker immediately to prevent all threads from expiring
                        endWorker(worker);
                        return null;
                    }
                }
            }
            if (job !is null) {
                //if this job has a rule, then we are essentially acquiring a lock
                if ((job.getRule() !is null) && !(cast(ThreadJob)job )) {
                    //don't need to re-aquire locks because it was not recorded in the graph
                    //that this thread waited to get this rule
                    manager.getLockManager().addLockThread(Thread.currentThread(), job.getRule());
                }
                //see if we need to wake another worker
                if (manager.sleepHint_package() <= 0)
                    jobQueued();
            }
        } finally {
            //decrement busy thread count if we're not running a job
            if (job is null)
                decrementBusyThreads();
        }
        return job;
    }
    package InternalJob startJob_package(Worker worker) {
        return startJob(worker);
    }
}
