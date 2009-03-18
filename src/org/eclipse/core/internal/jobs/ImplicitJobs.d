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
module org.eclipse.core.internal.jobs.ImplicitJobs;

import java.lang.Thread;
import java.lang.all;
import java.util.Iterator;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;
import java.util.HashSet;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.runtime.jobs.Job;

import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.ThreadJob;
import org.eclipse.core.internal.jobs.InternalJob;

/**
 * Implicit jobs are jobs that are running by virtue of a JobManager.begin/end
 * pair. They act like normal jobs, except they are tied to an arbitrary thread
 * of the client's choosing, and they can be nested.
 */
class ImplicitJobs {
    /**
     * Cached unused instance that can be reused
     */
    private ThreadJob jobCache = null;
    protected JobManager manager;

    /**
     * Set of suspended scheduling rules.
     */
    private const Set suspendedRules;

    /**
     * Maps (Thread->ThreadJob), threads to the currently running job for that
     * thread.
     */
    private final Map threadJobs;

    this(JobManager manager) {
        this.manager = manager;
        suspendedRules = new HashSet(20);
        threadJobs = new HashMap(20);
    }

    /* (Non-javadoc)
     * @see IJobManager#beginRule
     */
    void begin(ISchedulingRule rule, IProgressMonitor monitor, bool suspend) {
        if (JobManager.DEBUG_BEGIN_END)
            JobManager.debug_(Format("Begin rule: {}", rule)); //$NON-NLS-1$
        final Thread getThis = Thread.currentThread();
        ThreadJob threadJob;
        synchronized (this) {
            threadJob = cast(ThreadJob) threadJobs.get(getThis);
            if (threadJob !is null) {
                //nested rule, just push on stack and return
                threadJob.push(rule);
                return;
            }
            //no need to schedule a thread job for a null rule
            if (rule is null)
                return;
            //create a thread job for this thread, use the rule from the real job if it has one
            Job realJob = manager.currentJob();
            if (realJob !is null && realJob.getRule() !is null)
                threadJob = newThreadJob(realJob.getRule());
            else {
                threadJob = newThreadJob(rule);
                threadJob.acquireRule = true;
            }
            //don't acquire rule if it is a suspended rule
            if (isSuspended(rule))
                threadJob.acquireRule = false;
            //indicate if it is a system job to ensure isBlocking works correctly
            threadJob.setRealJob(realJob);
            threadJob.setThread(getThis);
        }
        try {
            threadJob.push(rule);
            //join the thread job outside sync block
            if (threadJob.acquireRule) {
                //no need to re-acquire any locks because the thread did not wait to get this lock
                if (manager.runNow_package(threadJob))
                    manager.getLockManager().addLockThread(Thread.currentThread(), rule);
                else
                    threadJob = threadJob.joinRun(monitor);
            }
        } finally {
            //remember this thread job  - only do this
            //after the rule is acquired because it is ok for this thread to acquire
            //and release other rules while waiting.
            synchronized (this) {
                threadJobs.put(getThis, threadJob);
                if (suspend)
                    suspendedRules.add(cast(Object)rule);
            }
            if (threadJob.isBlocked) {
                threadJob.isBlocked = false;
                manager.reportUnblocked(monitor);
            }
        }
    }

    /* (Non-javadoc)
     * @see IJobManager#endRule
     */
    synchronized void end(ISchedulingRule rule, bool resume) {
        if (JobManager.DEBUG_BEGIN_END)
            JobManager.debug_(Format("End rule: {}", rule)); //$NON-NLS-1$
        ThreadJob threadJob = cast(ThreadJob) threadJobs.get(Thread.currentThread());
        if (threadJob is null)
            Assert.isLegal(rule is null, Format("endRule without matching beginRule: {}", rule)); //$NON-NLS-1$
        else if (threadJob.pop(rule)) {
            endThreadJob(threadJob, resume);
        }
    }

    /**
     * Called when a worker thread has finished running a job. At this
     * point, the worker thread must not own any scheduling rules
     * @param lastJob The last job to run in this thread
     */
    void endJob(InternalJob lastJob) {
        final Thread getThis = Thread.currentThread();
        IStatus error;
        synchronized (this) {
            ThreadJob threadJob = cast(ThreadJob) threadJobs.get(getThis);
            if (threadJob is null) {
                if (lastJob.getRule() !is null)
                    notifyWaitingThreadJobs();
                return;
            }
            String msg = Format("Worker thread ended job: {}, but still holds rule: {}", lastJob, threadJob ); //$NON-NLS-1$ //$NON-NLS-2$
            error = new Status(IStatus.ERROR, JobManager.PI_JOBS, 1, msg, null);
            //end the thread job
            endThreadJob(threadJob, false);
        }
        try {
            RuntimeLog.log(error);
        } catch (RuntimeException e) {
            //failed to log, so print to console instead
            getDwtLogger.error( __FILE__, __LINE__, "{}", error.getMessage());
        }
    }

    private void endThreadJob(ThreadJob threadJob, bool resume) {
        Thread getThis = Thread.currentThread();
        //clean up when last rule scope exits
        threadJobs.remove(getThis);
        ISchedulingRule rule = threadJob.getRule();
        if (resume && rule !is null)
            suspendedRules.remove(cast(Object)rule);
        //if this job had a rule, then we are essentially releasing a lock
        //note it is safe to do this even if the acquire was aborted
        if (threadJob.acquireRule) {
            manager.getLockManager().removeLockThread(getThis, rule);
            notifyWaitingThreadJobs();
        }
        //if the job was started, we need to notify job manager to end it
        if (threadJob.isRunning())
            manager.endJob_package(threadJob, Status.OK_STATUS, false);
        recycle(threadJob);
    }

    /**
     * Returns true if this rule has been suspended, and false otherwise.
     */
    private bool isSuspended(ISchedulingRule rule) {
        if (suspendedRules.size() is 0)
            return false;
        for (Iterator it = suspendedRules.iterator(); it.hasNext();)
            if ((cast(ISchedulingRule) it.next()).contains(rule))
                return true;
        return false;
    }

    /**
     * Returns a new or reused ThreadJob instance.
     */
    private ThreadJob newThreadJob(ISchedulingRule rule) {
        if (jobCache !is null) {
            ThreadJob job = jobCache;
            job.setRule(rule);
            job.acquireRule = job.isRunning_ = false;
            job.realJob = null;
            jobCache = null;
            return job;
        }
        return new ThreadJob(manager, rule);
    }

    /**
     * A job has just finished that was holding a scheduling rule, and the
     * scheduling rule is now free.  Wake any blocked thread jobs so they can
     * compete for the newly freed lock
     */
    private void notifyWaitingThreadJobs() {
        synchronized (ThreadJob.mutex) {
            ThreadJob.condition.notifyAll();
        }
    }

    /**
     * Indicates that a thread job is no longer in use and can be reused.
     */
    private void recycle(ThreadJob job) {
        if (jobCache is null && job.recycle())
            jobCache = job;
    }

    /**
     * Implements IJobManager#resume(ISchedulingRule)
     * @param rule
     */
    void resume(ISchedulingRule rule) {
        //resume happens as a consequence of freeing the last rule in the stack
        end(rule, true);
        if (JobManager.DEBUG_BEGIN_END)
            JobManager.debug_(Format("Resume rule: {}", rule)); //$NON-NLS-1$
    }

    /**
     * Implements IJobManager#suspend(ISchedulingRule, IProgressMonitor)
     * @param rule
     * @param monitor
     */
    void suspend(ISchedulingRule rule, IProgressMonitor monitor) {
        if (JobManager.DEBUG_BEGIN_END)
            JobManager.debug_(Format("Suspend rule: {}", rule)); //$NON-NLS-1$
        //the suspend job will be remembered once the rule is acquired
        begin(rule, monitor, true);
    }

    /**
     * Implements IJobManager#transferRule(ISchedulingRule, Thread)
     */
    synchronized void transfer(ISchedulingRule rule, Thread destinationThread) {
        //nothing to do for null
        if (rule is null)
            return;
        Thread getThis = Thread.currentThread();
        //nothing to do if transferring to the same thread
        if (getThis is destinationThread)
            return;
        //ensure destination thread doesn't already have a rule
        ThreadJob job = cast(ThreadJob) threadJobs.get(destinationThread);
        Assert.isLegal(job is null);
        //ensure calling thread owns the job being transferred
        job = cast(ThreadJob) threadJobs.get(getThis);
        Assert.isNotNull(job);
        Assert.isLegal(job.getRule() is rule);
        //transfer the thread job without ending it
        job.setThread(destinationThread);
        threadJobs.remove(getThis);
        threadJobs.put(destinationThread, job);
        //transfer lock
        if (job.acquireRule) {
            manager.getLockManager().removeLockThread(getThis, rule);
            manager.getLockManager().addLockThread(destinationThread, rule);
        }
    }
}
