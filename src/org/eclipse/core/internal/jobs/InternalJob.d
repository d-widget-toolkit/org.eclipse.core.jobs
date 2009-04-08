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
module org.eclipse.core.internal.jobs.InternalJob;

import java.lang.all;
import java.util.Map;
import java.util.Set;
import java.lang.Thread;

import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.ListenerList;
import org.eclipse.core.runtime.PlatformObject;
import org.eclipse.core.runtime.QualifiedName;
import org.eclipse.core.runtime.jobs.IJobChangeListener;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.core.runtime.jobs.MultiRule;

import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.ObjectMap;


/**
 * Internal implementation class for jobs. Clients must not implement this class
 * directly.  All jobs must be subclasses of the API <code>org.eclipse.core.runtime.jobs.Job</code> class.
 */
public abstract class InternalJob : PlatformObject, Comparable {
    /**
     * Job state code (value 16) indicating that a job has been removed from
     * the wait queue and is about to start running. From an API point of view,
     * this is the same as RUNNING.
     */
    static const int ABOUT_TO_RUN = 0x10;

    /**
     * Job state code (value 32) indicating that a job has passed scheduling
     * precondition checks and is about to be added to the wait queue. From an API point of view,
     * this is the same as WAITING.
     */
    static const int ABOUT_TO_SCHEDULE = 0x20;
    /**
     * Job state code (value 8) indicating that a job is blocked by another currently
     * running job.  From an API point of view, this is the same as WAITING.
     */
    static const int BLOCKED = 0x08;

    //flag mask bits
    private static const int M_STATE = 0xFF;
    private static const int M_SYSTEM = 0x0100;
    private static const int M_USER = 0x0200;

    /*
     * flag on a job indicating that it was about to run, but has been canceled
     */
    private static const int M_ABOUT_TO_RUN_CANCELED = 0x0400;

    private static JobManager manager_;
    protected static JobManager manager(){
        if( manager_ is null ){
            synchronized( InternalJob.classinfo ){
                if( manager_ is null ){
                    manager_ = JobManager.getInstance();
                }
            }
        }
        return manager_;
    }
    private static int nextJobNumber = 0;

    /**
     * Start time constant indicating a job should be started at
     * a time in the infinite future, causing it to sleep forever.
     */
    static const long T_INFINITE = Long.MAX_VALUE;
    /**
     * Start time constant indicating that the job has no start time.
     */
    static const long T_NONE = -1;

    private /+volatile+/ int flags = Job.NONE;
    private const int jobNumber;
    private ListenerList listeners = null;
    private IProgressMonitor monitor;
    private String name;
    /**
     * The job ahead of me in a queue or list.
     */
    private InternalJob next_;
    /**
     * The job behind me in a queue or list.
     */
    private InternalJob previous_;
    private int priority = Job.LONG;
    /**
     * Arbitrary properties (key,value) pairs, attached
     * to a job instance by a third party.
     */
    private ObjectMap properties;
    private IStatus result;
    private ISchedulingRule schedulingRule;
    /**
     * If the job is waiting, this represents the time the job should start by.
     * If this job is sleeping, this represents the time the job should wake up.
     * If this job is running, this represents the delay automatic rescheduling,
     * or -1 if the job should not be rescheduled.
     */
    private long startTime;

    /**
     * Stamp added when a job is added to the wait queue. Used to ensure
     * jobs in the wait queue maintain their insertion order even if they are
     * removed from the wait queue temporarily while blocked
     */
    private long waitQueueStamp = T_NONE;

    /*
     * The thread that is currently running this job
     */
    private /+volatile+/ Thread thread = null;

    protected this(String name) {
        Assert.isNotNull(name);
        jobNumber = nextJobNumber++;
        this.name = name;
    }

    /* (non-Javadoc)
     * @see Job#addJobListener(IJobChangeListener)
     */
    protected void addJobChangeListener(IJobChangeListener listener) {
        if (listeners is null)
            listeners = new ListenerList(ListenerList.IDENTITY);
        listeners.add(cast(Object)listener);
    }
    package void addJobChangeListener_package(IJobChangeListener listener) {
        addJobChangeListener(listener);
    }

    /**
     * Adds an entry at the end of the list of which this item is the head.
     */
    final void addLast(InternalJob entry) {
        InternalJob last = this;
        //find the end of the queue
        while (last.previous_ !is null)
            last = last.previous_;
        //add the new entry to the end of the queue
        last.previous_ = entry;
        entry.next_ = last;
        entry.previous_ = null;
    }

    /* (non-Javadoc)
     * @see Job#belongsTo(Object)
     */
    protected bool belongsTo(Object family) {
        return false;
    }
    package bool belongsTo_package(Object family) {
        return belongsTo(family);
    }

    /* (non-Javadoc)
     * @see Job#cancel()
     */
    /*protected package*/ bool cancel() {
        return manager.cancel_package(this);
    }

    /* (non-Javadoc)
     * @see Job#canceling()
     */
    /*protected package*/ void canceling() {
        //default implementation does nothing
    }

    /* (on-Javadoc)
     * @see java.lang.Comparable#compareTo(java.lang.Object)
     */
    public final int compareTo(Object otherJob) {
        return (cast(InternalJob) otherJob).startTime >= startTime ? 1 : -1;
    }
    public final override int opCmp( Object object ){
        return compareTo( object );
    }

    /* (non-Javadoc)
     * @see Job#done(IStatus)
     */
    protected void done(IStatus endResult) {
        manager.endJob_package(this, endResult, true);
    }

    /**
     * Returns the job listeners that are only listening to this job.  Returns
     * <code>null</code> if this job has no listeners.
     */
    final ListenerList getListeners() {
        return listeners;
    }

    /* (non-Javadoc)
     * @see Job#getName()
     */
    protected String getName() {
        return name;
    }
    package String getName_package() {
        return name;
    }

    /* (non-Javadoc)
     * @see Job#getPriority()
     */
    /*protected package*/ int getPriority() {
        return priority;
    }

    /**
     * Returns the job's progress monitor, or null if it is not running.
     */
    final IProgressMonitor getProgressMonitor() {
        return monitor;
    }

    /* (non-Javadoc)
     * @see Job#getProperty
     */
    protected Object getProperty(QualifiedName key) {
        // thread safety: (Concurrency001 - copy on write)
        Map temp = properties;
        if (temp is null)
            return null;
        return temp.get(key);
    }

    /* (non-Javadoc)
     * @see Job#getResult
     */
    protected IStatus getResult() {
        return result;
    }

    /* (non-Javadoc)
     * @see Job#getRule
     */
    /*protected package*/ ISchedulingRule getRule() {
        return schedulingRule;
    }
    package ISchedulingRule getRule_package() {
        return getRule();
    }

    /**
     * Returns the time that this job should be started, awakened, or
     * rescheduled, depending on the current state.
     * @return time in milliseconds
     */
    final long getStartTime() {
        return startTime;
    }

    /* (non-Javadoc)
     * @see Job#getState()
     */
    protected int getState() {
        int state = flags & M_STATE;
        switch (state) {
            //blocked state is equivalent to waiting state for clients
            case BLOCKED :
                return Job.WAITING;
            case ABOUT_TO_RUN :
                return Job.RUNNING;
            case ABOUT_TO_SCHEDULE :
                return Job.WAITING;
            default :
                return state;
        }
    }
    package int getState_package() {
        return getState();
    }

    /* (non-javadoc)
     * @see Job.getThread
     */
    protected Thread getThread() {
        return thread;
    }
    package Thread getThread_package() {
        return getThread();
    }

    /**
     * Returns the raw job state, including internal states no exposed as API.
     */
    final int internalGetState() {
        return flags & M_STATE;
    }

    /**
     * Must be called from JobManager#setPriority
     */
    final void internalSetPriority(int newPriority) {
        this.priority = newPriority;
    }

    /**
     * Must be called from JobManager#setRule
     */
    final void internalSetRule(ISchedulingRule rule) {
        this.schedulingRule = rule;
    }

    /**
     * Must be called from JobManager#changeState
     */
    final void internalSetState(int i) {
        flags = (flags & ~M_STATE) | i;
    }

    /**
     * Returns whether this job was canceled when it was about to run
     */
    final bool isAboutToRunCanceled() {
        return (flags & M_ABOUT_TO_RUN_CANCELED) !is 0;
    }

    /* (non-Javadoc)
     * @see Job#isBlocking()
     */
    protected bool isBlocking() {
        return manager.isBlocking_package(this);
    }

    /**
     * Returns true if this job conflicts with the given job, and false otherwise.
     */
    final bool isConflicting(InternalJob otherJob) {
        ISchedulingRule otherRule = otherJob.getRule();
        if (schedulingRule is null || otherRule is null)
            return false;
        //if one of the rules is a compound rule, it must be asked the question.
        if (schedulingRule.classinfo is MultiRule.classinfo)
            return schedulingRule.isConflicting(otherRule);
        return otherRule.isConflicting(schedulingRule);
    }

    /* (non-javadoc)
     * @see Job.isSystem()
     */
    protected bool isSystem() {
        return (flags & M_SYSTEM) !is 0;
    }
    package bool isSystem_package() {
        return isSystem();
    }

    /* (non-javadoc)
     * @see Job.isUser()
     */
    protected bool isUser() {
        return (flags & M_USER) !is 0;
    }

    /* (non-Javadoc)
     * @see Job#join()
     */
    protected void join() {
        manager.join_package(this);
    }

    /**
     * Returns the next_ entry (ahead of this one) in the list, or null if there is no next_ entry
     */
    final InternalJob next() {
        return next_;
    }

    /**
     * Returns the previous_ entry (behind this one) in the list, or null if there is no previous_ entry
     */
    final InternalJob previous() {
        return previous_;
    }

    /**
     * Removes this entry from any list it belongs to.  Returns the receiver.
     */
    final InternalJob remove() {
        if (next_ !is null)
            next_.setPrevious(previous_);
        if (previous_ !is null)
            previous_.setNext(next_);
        next_ = previous_ = null;
        return this;
    }

    /* (non-Javadoc)
     * @see Job#removeJobListener(IJobChangeListener)
     */
    protected void removeJobChangeListener(IJobChangeListener listener) {
        if (listeners !is null)
            listeners.remove(cast(Object)listener);
    }
    package void removeJobChangeListener_package(IJobChangeListener listener) {
        removeJobChangeListener(listener);
    }

    /* (non-Javadoc)
     * @see Job#run(IProgressMonitor)
     */
    protected abstract IStatus run(IProgressMonitor progressMonitor);
    package IStatus run_package(IProgressMonitor progressMonitor){
        return run(progressMonitor);
    }

    /* (non-Javadoc)
     * @see Job#schedule(long)
     */
    protected void schedule(long delay) {
        if (shouldSchedule())
            manager.schedule_package(this, delay, false);
    }
    package void schedule_package(long delay) {
        schedule(delay);
    }

    /**
     * Sets whether this job was canceled when it was about to run
     */
    final void setAboutToRunCanceled(bool value) {
        flags = value ? flags | M_ABOUT_TO_RUN_CANCELED : flags & ~M_ABOUT_TO_RUN_CANCELED;

    }

    /* (non-Javadoc)
     * @see Job#setName(String)
     */
    protected void setName(String name) {
        Assert.isNotNull(name);
        this.name = name;
    }

    /**
     * Sets the next_ entry in this linked list of jobs.
     * @param entry
     */
    final void setNext(InternalJob entry) {
        this.next_ = entry;
    }

    /**
     * Sets the previous_ entry in this linked list of jobs.
     * @param entry
     */
    final void setPrevious(InternalJob entry) {
        this.previous_ = entry;
    }

    /* (non-Javadoc)
     * @see Job#setPriority(int)
     */
    protected void setPriority(int newPriority) {
        switch (newPriority) {
            case Job.INTERACTIVE :
            case Job.SHORT :
            case Job.LONG :
            case Job.BUILD :
            case Job.DECORATE :
                manager.setPriority_package(this, newPriority);
                break;
            default :
                throw new IllegalArgumentException(Integer.toString(newPriority));
        }
    }

    /* (non-Javadoc)
     * @see Job#setProgressGroup(IProgressMonitor, int)
     */
    protected void setProgressGroup(IProgressMonitor group, int ticks) {
        Assert.isNotNull(cast(Object)group);
        IProgressMonitor pm = manager.createMonitor_package(this, group, ticks);
        if (pm !is null)
            setProgressMonitor(pm);
    }

    /**
     * Sets the progress monitor to use for the next_ execution of this job,
     * or for clearing the monitor when a job completes.
     * @param monitor a progress monitor
     */
    final void setProgressMonitor(IProgressMonitor monitor) {
        this.monitor = monitor;
    }

    /* (non-Javadoc)
     * @see Job#setProperty(QualifiedName,Object)
     */
    protected void setProperty(QualifiedName key, Object value) {
        // thread safety: (Concurrency001 - copy on write)
        if (value is null) {
            if (properties is null)
                return;
            ObjectMap temp = cast(ObjectMap) properties.clone();
            temp.remove(key);
            if (temp.isEmpty())
                properties = null;
            else
                properties = temp;
        } else {
            ObjectMap temp = properties;
            if (temp is null)
                temp = new ObjectMap(5);
            else
                temp = cast(ObjectMap) properties.clone();
            temp.put(key, value);
            properties = temp;
        }
    }

    /**
     * Sets or clears the result of an execution of this job.
     * @param result a result status, or <code>null</code>
     */
    final void setResult(IStatus result) {
        this.result = result;
    }

    /* (non-Javadoc)
     * @see Job#setRule(ISchedulingRule)
     */
    protected void setRule(ISchedulingRule rule) {
        manager.setRule(this, rule);
    }

    /**
     * Sets a time to start, wake up, or schedule this job,
     * depending on the current state
     * @param time a time in milliseconds
     */
    final void setStartTime(long time) {
        startTime = time;
    }

    /* (non-javadoc)
     * @see Job.setSystem
     */
    protected void setSystem(bool value) {
        if (getState() !is Job.NONE)
            throw new IllegalStateException();
        flags = value ? flags | M_SYSTEM : flags & ~M_SYSTEM;
    }

    /* (non-javadoc)
     * @see Job.setThread
     */
    protected void setThread(Thread thread) {
        this.thread = thread;
    }
    package void setThread_package(Thread thread) {
        setThread(thread);
    }

    /* (non-javadoc)
     * @see Job.setUser
     */
    protected void setUser(bool value) {
        if (getState() !is Job.NONE)
            throw new IllegalStateException();
        flags = value ? flags | M_USER : flags & ~M_USER;
    }

    /* (Non-javadoc)
     * @see Job#shouldSchedule
     */
    protected bool shouldSchedule() {
        return true;
    }
    package bool shouldSchedule_package() {
        return shouldSchedule();
    }

    /* (non-Javadoc)
     * @see Job#sleep()
     */
    protected bool sleep() {
        return manager.sleep_package(this);
    }

    /* (non-Javadoc)
     * Prints a string-based representation of this job instance.
     * For debugging purposes only.
     */
    public String toString() {
        return Format( "{}({})", getName(), jobNumber ); //$NON-NLS-1$//$NON-NLS-2$
    }

    /* (non-Javadoc)
     * @see Job#wakeUp(long)
     */
    protected void wakeUp(long delay) {
        manager.wakeUp_package(this, delay);
    }

    /**
     * @param waitQueueStamp The waitQueueStamp to set.
     */
    void setWaitQueueStamp(long waitQueueStamp) {
        this.waitQueueStamp = waitQueueStamp;
    }

    /**
     * @return Returns the waitQueueStamp.
     */
    long getWaitQueueStamp() {
        return waitQueueStamp;
    }
}
