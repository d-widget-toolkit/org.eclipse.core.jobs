/*******************************************************************************
 * Copyright (c) 2004, 2007 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.ThreadJob;

import java.lang.all;
import java.util.Set;
import java.lang.Thread;
import tango.core.sync.Mutex;
import tango.core.sync.Condition;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.InternalJob;
import org.eclipse.core.internal.jobs.LockManager;

/**
 * Captures the implicit job state for a given thread.
 */
class ThreadJob : Job {
    /**
     * The notifier is a shared object used to wake up waiting thread jobs
     * when another job completes that is releasing a scheduling rule.
     */

    static const Mutex mutex;
    static const Condition condition;
    static this(){
        mutex = new Mutex();
        condition = new Condition(mutex);
    }

    private const JobManager manager;
    /**
     * Set to true if this thread job is running in a thread that did
     * not own a rule already.  This means it needs to acquire the
     * rule during beginRule, and must release the rule during endRule.
     */
    /+protected+/ bool acquireRule = false;

    /**
     * Indicates that this thread job did report to the progress manager
     * that it will be blocked, and therefore when it begins it must
     * be reported to the job manager when it is no longer blocked.
     */
    bool isBlocked = false;

    /**
     * True if this ThreadJob has begun execution
     */
    /+protected+/ bool isRunning_ = false;

    /**
     * Used for diagnosing mismatched begin/end pairs. This field
     * is only used when in debug mode, to capture the stack trace
     * of the last call to beginRule.
     */
    private RuntimeException lastPush = null;
    /**
     * The actual job that is running in the thread that this
     * ThreadJob represents.  This will be null if this thread
     * job is capturing a rule acquired outside of a job.
     */
    /*protected package*/ Job realJob;
    /**
     * The stack of rules that have been begun in this thread, but not yet ended.
     */
    private ISchedulingRule[] ruleStack;
    /**
     * Rule stack pointer.
     */
    private int top;

    this(JobManager manager, ISchedulingRule rule) {
        super("Implicit Job"); //$NON-NLS-1$
        this.manager = manager;
        setSystem(true);
        setPriority(Job.INTERACTIVE);
        ruleStack = new ISchedulingRule[2];
        top = -1;
        setRule(rule);
    }

    /**
     * An endRule was called that did not match the last beginRule in
     * the stack.  Report and log a detailed informational message.
     * @param rule The rule that was popped
     */
    private void illegalPop(ISchedulingRule rule) {
        StringBuffer buf = new StringBuffer("Attempted to endRule: "); //$NON-NLS-1$
        buf.append(Format("{}",rule));
        if (top >= 0 && top < ruleStack.length) {
            buf.append(", does not match most recent begin: "); //$NON-NLS-1$
            buf.append(Format("{}",ruleStack[top]));
        } else {
            if (top < 0)
                buf.append(", but there was no matching beginRule"); //$NON-NLS-1$
            else
                buf.append( Format(", but the rule stack was out of bounds: {}", top)); //$NON-NLS-1$
        }
        buf.append(".  See log for trace information if rule tracing is enabled."); //$NON-NLS-1$
        String msg = buf.toString();
        if (JobManager.DEBUG || JobManager.DEBUG_BEGIN_END) {
            getDwtLogger.info( __FILE__, __LINE__, "{}",msg);
            Exception t = lastPush is null ? cast(Exception)new IllegalArgumentException("") : cast(Exception)lastPush;
            IStatus error = new Status(IStatus.ERROR, JobManager.PI_JOBS, 1, msg, t);
            RuntimeLog.log(error);
        }
        Assert.isLegal(false, msg);
    }

    /**
     * Client has attempted to begin a rule that is not contained within
     * the outer rule.
     */
    private void illegalPush(ISchedulingRule pushRule, ISchedulingRule baseRule) {
        StringBuffer buf = new StringBuffer("Attempted to beginRule: "); //$NON-NLS-1$
        buf.append(Format("{}",pushRule));
        buf.append(", does not match outer scope rule: "); //$NON-NLS-1$
        buf.append(Format("{}",baseRule));
        String msg = buf.toString();
        if (JobManager.DEBUG) {
            getDwtLogger.info( __FILE__, __LINE__, "{}",msg);
            IStatus error = new Status(IStatus.ERROR, JobManager.PI_JOBS, 1, msg, new IllegalArgumentException(""));
            RuntimeLog.log(error);
        }
        Assert.isLegal(false, msg);

    }

    /**
     * Returns true if the monitor is canceled, and false otherwise.
     * Protects the caller from exception in the monitor implementation.
     */
    private bool isCanceled(IProgressMonitor monitor) {
        try {
            return monitor.isCanceled();
        } catch (RuntimeException e) {
            //logged message should not be translated
            IStatus status = new Status(IStatus.ERROR, JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, "ThreadJob.isCanceled", e); //$NON-NLS-1$
            RuntimeLog.log(status);
        }
        return false;
    }

    /**
     * Returns true if this thread job was scheduled and actually started running.
     */
    bool isRunning() {
        synchronized(mutex){
            return isRunning_;
        }
    }

    /**
     * Schedule the job and block the calling thread until the job starts running.
     * Returns the ThreadJob instance that was started.
     */
    ThreadJob joinRun(IProgressMonitor monitor) {
        if (isCanceled(monitor))
            throw new OperationCanceledException();
        //check if there is a blocking thread before waiting
        InternalJob blockingJob = manager.findBlockingJob_package(this);
        Thread blocker = blockingJob is null ? null : blockingJob.getThread_package();
        ThreadJob result = this;
        try {
            //just return if lock listener decided to grant immediate access
            if (manager.getLockManager().aboutToWait(blocker))
                return this;
            try {
                waitStart(monitor, blockingJob);
                final Thread getThis = Thread.currentThread();
                while (true) {
                    if (isCanceled(monitor))
                        throw new OperationCanceledException();
                    //try to run the job
                    if (manager.runNow_package(this))
                        return this;
                    //update blocking job
                    blockingJob = manager.findBlockingJob_package(this);
                    //the rule could have been transferred to this thread while we were waiting
                    blocker = blockingJob is null ? null : blockingJob.getThread_package();
                    if (blocker is getThis && cast(ThreadJob)blockingJob ) {
                        //now we are just the nested acquire case
                        result = cast(ThreadJob) blockingJob;
                        result.push(getRule());
                        result.isBlocked = this.isBlocked;
                        return result;
                    }
                    //just return if lock listener decided to grant immediate access
                    if (manager.getLockManager().aboutToWait(blocker))
                        return this;
                    //must lock instance before calling wait
                    synchronized (mutex) {
                        try {
                            condition.wait(0.250);
                        } catch (InterruptedException e) {
                            //ignore
                        }
                    }
                }
            } finally {
                if (this is result)
                    waitEnd(monitor);
            }
        } finally {
            manager.getLockManager().aboutToRelease();
        }
    }

    /**
     * Pops a rule. Returns true if it was the last rule for this thread
     * job, and false otherwise.
     */
    bool pop(ISchedulingRule rule) {
        if (top < 0 || ruleStack[top] !is rule)
            illegalPop(rule);
        ruleStack[top--] = null;
        return top < 0;
    }

    /**
     * Adds a new scheduling rule to the stack of rules for this thread. Throws
     * a runtime exception if the new rule is not compatible with the base
     * scheduling rule for this thread.
     */
    void push(ISchedulingRule rule) {
        ISchedulingRule baseRule = getRule();
        if (++top >= ruleStack.length) {
            ISchedulingRule[] newStack = new ISchedulingRule[ruleStack.length * 2];
            SimpleType!(ISchedulingRule).arraycopy(ruleStack, 0, newStack, 0, ruleStack.length);
            ruleStack = newStack;
        }
        ruleStack[top] = rule;
        if (JobManager.DEBUG_BEGIN_END)
            lastPush = new RuntimeException()/+).fillInStackTrace()+/;
        //check for containment last because we don't want to fail again on endRule
        if (baseRule !is null && rule !is null && !baseRule.contains(rule))
            illegalPush(rule, baseRule);
    }

    /**
     * Reset all of this job's fields so it can be reused.  Returns false if
     * reuse is not possible
     */
    bool recycle() {
        //don't recycle if still running for any reason
        if (getState() !is Job.NONE)
            return false;
        //clear and reset all fields
        acquireRule = isRunning_ = isBlocked = false;
        realJob = null;
        setRule(null);
        setThread(null);
        if (ruleStack.length !is 2)
            ruleStack = new ISchedulingRule[2];
        else
            ruleStack[0] = ruleStack[1] = null;
        top = -1;
        return true;
    }

    /** (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.Job#run(org.eclipse.core.runtime.IProgressMonitor)
     */
    public IStatus run(IProgressMonitor monitor) {
        synchronized (this) {
            isRunning_ = true;
        }
        return ASYNC_FINISH;
    }

    /**
     * Records the job that is actually running in this thread, if any
     * @param realJob The running job
     */
    void setRealJob(Job realJob) {
        this.realJob = realJob;
    }

    /**
     * Returns true if this job should cause a self-canceling job
     * to cancel itself, and false otherwise.
     */
    bool shouldInterrupt() {
        return realJob is null ? true : !realJob.isSystem();
    }

    /* (non-javadoc)
     * For debugging purposes only
     */
    public String toString() {
        StringBuffer buf = new StringBuffer("ThreadJob"); //$NON-NLS-1$
        buf.append('(').append(Format("{}",realJob)).append(',').append('[');
        for (int i = 0; i <= top && i < ruleStack.length; i++)
            buf.append(Format("{}",ruleStack[i])).append(',');
        buf.append(']').append(')');
        return buf.toString();
    }

    /**
     * Reports that this thread was blocked, but is no longer blocked and is able
     * to proceed.
     * @param monitor The monitor to report unblocking to.
     */
    private void waitEnd(IProgressMonitor monitor) {
        final LockManager lockManager = manager.getLockManager();
        final Thread getThis = Thread.currentThread();
        if (isRunning()) {
            lockManager.addLockThread(getThis, getRule());
            //need to re-acquire any locks that were suspended while this thread was blocked on the rule
            lockManager.resumeSuspendedLocks(getThis);
        } else {
            //tell lock manager that this thread gave up waiting
            lockManager.removeLockWaitThread(getThis, getRule());
        }
    }

    /**
     * Indicates the start of a wait on a scheduling rule. Report the
     * blockage to the progress manager and update the lock manager.
     * @param monitor The monitor to report blocking to
     * @param blockingJob The job that is blocking this thread, or <code>null</code>
     */
    private void waitStart(IProgressMonitor monitor, InternalJob blockingJob) {
        manager.getLockManager().addLockWaitThread(Thread.currentThread(), getRule());
        isBlocked = true;
        manager.reportBlocked(monitor, blockingJob);
    }
}
