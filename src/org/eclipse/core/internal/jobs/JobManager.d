/*******************************************************************************
 * Copyright (c) 2003, 2007 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.JobManager;

import java.lang.all;
import java.util.Collections;
import java.util.List;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Set;
import java.util.HashSet;
import tango.time.WallClock;
import tango.time.Time;
import java.lang.Thread;

//don't use ICU because this is used for debugging only (see bug 135785)
// import java.text.DateFormat;
// import java.text.FieldPosition;
// import java.text.SimpleDateFormat;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IProgressMonitorWithBlocking;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.NullProgressMonitor;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.IJobChangeEvent;
import org.eclipse.core.runtime.jobs.IJobChangeListener;
import org.eclipse.core.runtime.jobs.IJobManager;
import org.eclipse.core.runtime.jobs.ILock;
import org.eclipse.core.runtime.jobs.ISchedulingRule;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.core.runtime.jobs.JobChangeAdapter;
import org.eclipse.core.runtime.jobs.LockListener;
import org.eclipse.core.runtime.jobs.ProgressProvider;
import org.eclipse.osgi.util.NLS;

import org.eclipse.core.internal.jobs.ImplicitJobs;
import org.eclipse.core.internal.jobs.WorkerPool;
import org.eclipse.core.internal.jobs.JobListeners;
import org.eclipse.core.internal.jobs.LockManager;
import org.eclipse.core.internal.jobs.JobQueue;
import org.eclipse.core.internal.jobs.InternalJob;
import org.eclipse.core.internal.jobs.ThreadJob;
import org.eclipse.core.internal.jobs.JobOSGiUtils;
import org.eclipse.core.internal.jobs.Worker;
import org.eclipse.core.internal.jobs.Semaphore;
import org.eclipse.core.internal.jobs.JobChangeEvent;
import org.eclipse.core.internal.jobs.JobMessages;
import org.eclipse.core.internal.jobs.JobStatus;

/**
 * Implementation of API type IJobManager
 *
 * Implementation note: all the data structures of this class are protected
 * by a single lock object held as a private field in this class.  The JobManager
 * instance itself is not used because this class is publicly reachable, and third
 * party clients may try to synchronize on it.
 *
 * The WorkerPool class uses its own monitor for synchronizing its data
 * structures. To avoid deadlock between the two classes, the JobManager
 * must NEVER call the worker pool while its own monitor is held.
 */
public class JobManager : IJobManager {

    /**
     * The unique identifier constant of this plug-in.
     */
    public static const String PI_JOBS = "org.eclipse.core.jobs"; //$NON-NLS-1$

    /**
     * Status code constant indicating an error occurred while running a plug-in.
     * For backward compatibility with Platform.PLUGIN_ERROR left at (value = 2).
     */
    public static const int PLUGIN_ERROR = 2;

    private static const String OPTION_DEADLOCK_ERROR = PI_JOBS ~ "/jobs/errorondeadlock"; //$NON-NLS-1$
    private static const String OPTION_DEBUG_BEGIN_END = PI_JOBS ~ "/jobs/beginend"; //$NON-NLS-1$
    private static const String OPTION_DEBUG_JOBS = PI_JOBS ~ "/jobs"; //$NON-NLS-1$
    private static const String OPTION_DEBUG_JOBS_TIMING = PI_JOBS ~ "/jobs/timing"; //$NON-NLS-1$
    private static const String OPTION_LOCKS = PI_JOBS ~ "/jobs/locks"; //$NON-NLS-1$
    private static const String OPTION_SHUTDOWN = PI_JOBS ~ "/jobs/shutdown"; //$NON-NLS-1$

    static bool DEBUG = false;
    static bool DEBUG_BEGIN_END = false;
    static bool DEBUG_DEADLOCK = false;
    static bool DEBUG_LOCKS = false;
    static bool DEBUG_TIMING = false;
    static bool DEBUG_SHUTDOWN = false;
//     private static DateFormat DEBUG_FORMAT;

    /**
     * The singleton job manager instance. It must be a singleton because
     * all job instances maintain a reference (as an optimization) and have no way
     * of updating it.
     */
    private static JobManager instance = null;
    /**
     * Scheduling rule used for validation of client-defined rules.
     */
    private static ISchedulingRule nullRule;
    private static void initNullRule(){
        if( nullRule !is null ) return;
        nullRule = new class ISchedulingRule {
            public bool contains(ISchedulingRule rule) {
                return rule is this;
            }

            public bool isConflicting(ISchedulingRule rule) {
                return rule is this;
            }
        };
    }

    /**
     * True if this manager is active, and false otherwise.  A job manager
     * starts out active, and becomes inactive if it has been shutdown
     * and not restarted.
     */
    private /+volatile+/ bool active = true;

    const ImplicitJobs implicitJobs;

    private const JobListeners jobListeners;

    /**
     * The lock for synchronizing all activity in the job manager.  To avoid deadlock,
     * this lock must never be held for extended periods, and must never be
     * held while third party code is being called.
     */
    private const Object lock;

    private const LockManager lockManager;

    /**
     * The pool of worker threads.
     */
    private WorkerPool pool;

    private ProgressProvider progressProvider = null;
    /**
     * Jobs that are currently running. Should only be modified from changeState
     */
    private const HashSet running;

    /**
     * Jobs that are sleeping.  Some sleeping jobs are scheduled to wake
     * up at a given start time, while others will sleep indefinitely until woken.
     * Should only be modified from changeState
     */
    private const JobQueue sleeping;
    /**
     * True if this manager has been suspended, and false otherwise.  A job manager
     * starts out not suspended, and becomes suspended when <code>suspend</code>
     * is invoked. Once suspended, no jobs will start running until <code>resume</code>
     * is called.
     */
    private bool suspended = false;

    /**
     * jobs that are waiting to be run. Should only be modified from changeState
     */
    private const JobQueue waiting;

    /**
     * Counter to record wait queue insertion order.
     */
    private long waitQueueCounter;

    public static void debug_(String msg) {
        StringBuffer msgBuf = new StringBuffer(msg.length + 40);
        if (DEBUG_TIMING) {
            //lazy initialize to avoid overhead when not debugging
//             if (DEBUG_FORMAT is null)
//                 DEBUG_FORMAT = new SimpleDateFormat("HH:mm:ss.SSS"); //$NON-NLS-1$
//             DEBUG_FORMAT.format(new Date(), msgBuf, new FieldPosition(0));
            auto time = WallClock.now();
            msgBuf.append(Format("{:d2}:{:d2}:{:d2}:{:d3}",
                time.time.span.hours,
                time.time.span.minutes,
                time.time.span.seconds,
                time.time.span.millis ));
            msgBuf.append('-');
        }
        msgBuf.append('[');
        msgBuf.append(Thread.currentThread().toString());
        msgBuf.append(']');
        msgBuf.append(msg);
        getDwtLogger.info( __FILE__, __LINE__, "{}", msgBuf.toString());
    }

    /**
     * Returns the job manager singleton. For internal use only.
     */
    static synchronized JobManager getInstance() {
        if (instance is null)
            new JobManager();
        return instance;
    }

    /**
     * For debugging purposes only
     */
    private static String printJobName(Job job) {
        if (cast(ThreadJob)job ) {
            Job realJob = (cast(ThreadJob) job).realJob;
            if (realJob !is null)
                return realJob.classinfo.name;
            return Format("ThreadJob on rule: {}", job.getRule()); //$NON-NLS-1$
        }
        return job.classinfo.name;
    }

    /**
     * For debugging purposes only
     */
    public static String printState(int state) {
        switch (state) {
            case Job.NONE :
                return "NONE"; //$NON-NLS-1$
            case Job.WAITING :
                return "WAITING"; //$NON-NLS-1$
            case Job.SLEEPING :
                return "SLEEPING"; //$NON-NLS-1$
            case Job.RUNNING :
                return "RUNNING"; //$NON-NLS-1$
            case InternalJob.BLOCKED :
                return "BLOCKED"; //$NON-NLS-1$
            case InternalJob.ABOUT_TO_RUN :
                return "ABOUT_TO_RUN"; //$NON-NLS-1$
            case InternalJob.ABOUT_TO_SCHEDULE :
                return "ABOUT_TO_SCHEDULE";//$NON-NLS-1$
            default:
        }
        return "UNKNOWN"; //$NON-NLS-1$
    }

    /**
     * Note that although this method is not API, clients have historically used
     * it to force jobs shutdown in cases where OSGi shutdown does not occur.
     * For this reason, this method should be considered near-API and should not
     * be changed if at all possible.
     */
    public static void shutdown() {
        if (instance !is null) {
            instance.doShutdown();
            instance = null;
        }
    }

    private this() {
        // SWT instance init
        implicitJobs = new ImplicitJobs(this);
        jobListeners = new JobListeners();
        lock = new Object();
        lockManager = new LockManager();

        instance = this;

        initDebugOptions();
        synchronized (lock) {
            waiting = new JobQueue(false);
            sleeping = new JobQueue(true);
            running = new HashSet(10);
            pool = new WorkerPool(this);
        }
        pool.setDaemon(JobOSGiUtils.getDefault().useDaemonThreads());
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#addJobListener(org.eclipse.core.runtime.jobs.IJobChangeListener)
     */
    public void addJobChangeListener(IJobChangeListener listener) {
        jobListeners.add(listener);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#beginRule(org.eclipse.core.runtime.jobs.ISchedulingRule, org.eclipse.core.runtime.IProgressMonitor)
     */
    public void beginRule(ISchedulingRule rule, IProgressMonitor monitor) {
        validateRule(rule);
        implicitJobs.begin(rule, monitorFor(monitor), false);
    }

    /**
     * Cancels a job
     */
    protected bool cancel(InternalJob job) {
        IProgressMonitor monitor = null;
        synchronized (lock) {
            switch (job.getState_package()) {
                case Job.NONE :
                    return true;
                case Job.RUNNING :
                    //cannot cancel a job that has already started (as opposed to ABOUT_TO_RUN)
                    if (job.internalGetState() is Job.RUNNING) {
                        monitor = job.getProgressMonitor();
                        break;
                    }
                    //signal that the job should be canceled before it gets a chance to run
                    job.setAboutToRunCanceled(true);
                    return true;
                default :
                    changeState(job, Job.NONE);
            }
        }
        //call monitor outside sync block
        if (monitor !is null) {
            if (!monitor.isCanceled()) {
                monitor.setCanceled(true);
                job.canceling();
            }
            return false;
        }
        //only notify listeners if the job was waiting or sleeping
        jobListeners.done(cast(Job) job, Status.CANCEL_STATUS, false);
        return true;
    }
    package bool cancel_package(InternalJob job) {
        return cancel(job);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#cancel(java.lang.String)
     */
    public void cancel(Object family) {
        //don't synchronize because cancel calls listeners
        for (Iterator it = select(family).iterator(); it.hasNext();)
            cancel(cast(InternalJob) it.next());
    }

    /**
     * Atomically updates the state of a job, adding or removing from the
     * necessary queues or sets.
     */
    private void changeState(InternalJob job, int newState) {
        bool blockedJobs = false;
        synchronized (lock) {
            int oldState = job.internalGetState();
            switch (oldState) {
                case Job.NONE :
                case InternalJob.ABOUT_TO_SCHEDULE :
                    break;
                case InternalJob.BLOCKED :
                    //remove this job from the linked list of blocked jobs
                    job.remove();
                    break;
                case Job.WAITING :
                    try {
                        waiting.remove(job);
                    } catch (RuntimeException e) {
                        Assert.isLegal(false, "Tried to remove a job that wasn't in the queue"); //$NON-NLS-1$
                    }
                    break;
                case Job.SLEEPING :
                    try {
                        sleeping.remove(job);
                    } catch (RuntimeException e) {
                        Assert.isLegal(false, "Tried to remove a job that wasn't in the queue"); //$NON-NLS-1$
                    }
                    break;
                case Job.RUNNING :
                case InternalJob.ABOUT_TO_RUN :
                    running.remove(job);
                    //add any blocked jobs back to the wait queue
                    InternalJob blocked = job.previous();
                    job.remove();
                    blockedJobs = blocked !is null;
                    while (blocked !is null) {
                        InternalJob previous = blocked.previous();
                        changeState(blocked, Job.WAITING);
                        blocked = previous;
                    }
                    break;
                default :
                    Assert.isLegal(false, Format("Invalid job state: {}, state: {}", job, oldState)); //$NON-NLS-1$ //$NON-NLS-2$
            }
            job.internalSetState(newState);
            switch (newState) {
                case Job.NONE :
                    job.setStartTime(InternalJob.T_NONE);
                    job.setWaitQueueStamp(InternalJob.T_NONE);
                case InternalJob.BLOCKED :
                    break;
                case Job.WAITING :
                    waiting.enqueue(job);
                    break;
                case Job.SLEEPING :
                    try {
                        sleeping.enqueue(job);
                    } catch (RuntimeException e) {
                        throw new RuntimeException(Format("Error changing from state: ", oldState)); //$NON-NLS-1$
                    }
                    break;
                case Job.RUNNING :
                case InternalJob.ABOUT_TO_RUN :
                    job.setStartTime(InternalJob.T_NONE);
                    job.setWaitQueueStamp(InternalJob.T_NONE);
                    running.add(job);
                    break;
                case InternalJob.ABOUT_TO_SCHEDULE :
                    break;
                default :
                    Assert.isLegal(false, Format("Invalid job state: {}, state: {}", job, newState)); //$NON-NLS-1$ //$NON-NLS-2$
            }
        }
        //notify queue outside sync block
        if (blockedJobs)
            pool.jobQueued();
    }

    /**
     * Returns a new progress monitor for this job, belonging to the given
     * progress group.  Returns null if it is not a valid time to set the job's group.
     */
    protected IProgressMonitor createMonitor(InternalJob job, IProgressMonitor group, int ticks) {
        synchronized (lock) {
            //group must be set before the job is scheduled
            //this includes the ABOUT_TO_SCHEDULE state, during which it is still
            //valid to set the progress monitor
            if (job.getState_package() !is Job.NONE)
                return null;
            IProgressMonitor monitor = null;
            if (progressProvider !is null)
                monitor = progressProvider.createMonitor(cast(Job) job, group, ticks);
            if (monitor is null)
                monitor = new NullProgressMonitor();
            return monitor;
        }
    }
    package IProgressMonitor createMonitor_package(InternalJob job, IProgressMonitor group, int ticks) {
        return createMonitor(job, group, ticks);
    }

    /**
     * Returns a new progress monitor for this job.  Never returns null.
     */
    private IProgressMonitor createMonitor(Job job) {
        IProgressMonitor monitor = null;
        if (progressProvider !is null)
            monitor = progressProvider.createMonitor(job);
        if (monitor is null)
            monitor = new NullProgressMonitor();
        return monitor;
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#createProgressGroup()
     */
    public IProgressMonitor createProgressGroup() {
        if (progressProvider !is null)
            return progressProvider.createProgressGroup();
        return new NullProgressMonitor();
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#currentJob()
     */
    public Job currentJob() {
        Thread current = Thread.currentThread();
        if (cast(Worker)current )
            return (cast(Worker) current).currentJob();
        synchronized (lock) {
            for (Iterator it = running.iterator(); it.hasNext();) {
                Job job = cast(Job) it.next();
                if (job.getThread() is current)
                    return job;
            }
        }
        return null;
    }

    /**
     * Returns the delay in milliseconds that a job with a given priority can
     * tolerate waiting.
     */
    private long delayFor(int priority) {
        //these values may need to be tweaked based on machine speed
        switch (priority) {
            case Job.INTERACTIVE :
                return 0L;
            case Job.SHORT :
                return 50L;
            case Job.LONG :
                return 100L;
            case Job.BUILD :
                return 500L;
            case Job.DECORATE :
                return 1000L;
            default :
                Assert.isTrue(false, Format("Job has invalid priority: {}", priority)); //$NON-NLS-1$
                return 0;
        }
    }

    /**
     * Performs the scheduling of a job.  Does not perform any notifications.
     */
    private void doSchedule(InternalJob job, long delay) {
        synchronized (lock) {
            //if it's a decoration job with no rule, don't run it right now if the system is busy
            if (job.getPriority() is Job.DECORATE && job.getRule() is null) {
                long minDelay = running.size() * 100;
                delay = Math.max(delay, minDelay);
            }
            if (delay > 0) {
                job.setStartTime(System.currentTimeMillis() + delay);
                changeState(job, Job.SLEEPING);
            } else {
                job.setStartTime(System.currentTimeMillis() + delayFor(job.getPriority()));
                job.setWaitQueueStamp(waitQueueCounter++);
                changeState(job, Job.WAITING);
            }
        }
    }

    /**
     * Shuts down the job manager.  Currently running jobs will be told
     * to stop, but worker threads may still continue processing.
     * (note: This implemented IJobManager.shutdown which was removed
     * due to problems caused by premature shutdown)
     */
    private void doShutdown() {
        Job[] toCancel = null;
        synchronized (lock) {
            if (active) {
                active = false;
                //cancel all running jobs
                toCancel = arraycast!(Job)( running.toArray());
                //clean up
                sleeping.clear();
                waiting.clear();
                running.clear();
            }
        }

        // Give running jobs a chance to finish. Wait 0.1 seconds for up to 3 times.
        if (toCancel !is null && toCancel.length > 0) {
            for (int i = 0; i < toCancel.length; i++) {
                cancel(cast(InternalJob)toCancel[i]); // cancel jobs outside sync block to avoid deadlock
            }

            for (int waitAttempts = 0; waitAttempts < 3; waitAttempts++) {
                Thread.yield();
                synchronized (lock) {
                    if (running.isEmpty())
                        break;
                }
                if (DEBUG_SHUTDOWN) {
                    JobManager.debug_(Format("Shutdown - job wait cycle #{}", (waitAttempts + 1))); //$NON-NLS-1$
                    Job[] stillRunning = null;
                    synchronized (lock) {
                        stillRunning = arraycast!(Job)( running.toArray());
                    }
                    if (stillRunning !is null) {
                        for (int j = 0; j < stillRunning.length; j++) {
                            JobManager.debug_(Format("\tJob: {}", printJobName(stillRunning[j]))); //$NON-NLS-1$
                        }
                    }
                }
                try {
                    Thread.sleep(100);
                } catch (InterruptedException e) {
                    //ignore
                }
                Thread.yield();
            }

            synchronized (lock) { // retrieve list of the jobs that are still running
                toCancel = arraycast!(Job)( running.toArray());
            }
        }

        if (toCancel !is null) {
            for (int i = 0; i < toCancel.length; i++) {
                String jobName = printJobName(toCancel[i]);
                //this doesn't need to be translated because it's just being logged
                String msg = "Job found still running after platform shutdown.  Jobs should be canceled by the plugin that scheduled them during shutdown: " ~ jobName; //$NON-NLS-1$
                RuntimeLog.log(new Status(IStatus.WARNING, JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, msg, null));

                // TODO the RuntimeLog.log in its current implementation won't produce a log
                // during this stage of shutdown. For now add a standard error output.
                // One the logging story is improved, the System.err output below can be removed:
                getDwtLogger.error( __FILE__, __LINE__, "{}", msg);
            }
        }

        pool.shutdown_package();
    }

    /**
     * Indicates that a job was running, and has now finished.  Note that this method
     * can be called under OutOfMemoryError conditions and thus must be paranoid
     * about allocating objects.
     */
    protected void endJob(InternalJob job, IStatus result, bool notify) {
        long rescheduleDelay = InternalJob.T_NONE;
        synchronized (lock) {
            //if the job is finishing asynchronously, there is nothing more to do for now
            if (result is Job.ASYNC_FINISH)
                return;
            //if job is not known then it cannot be done
            if (job.getState_package() is Job.NONE)
                return;
            if (JobManager.DEBUG && notify)
                JobManager.debug_(Format("Ending job: {}", job)); //$NON-NLS-1$
            job.setResult(result);
            job.setProgressMonitor(null);
            job.setThread_package(null);
            rescheduleDelay = job.getStartTime();
            changeState(job, Job.NONE);
        }
        //notify listeners outside sync block
        final bool reschedule = active && rescheduleDelay > InternalJob.T_NONE && job.shouldSchedule_package();
        if (notify)
            jobListeners.done(cast(Job) job, result, reschedule);
        //reschedule the job if requested and we are still active
        if (reschedule)
            schedule(job, rescheduleDelay, reschedule);
    }
    package void endJob_package(InternalJob job, IStatus result, bool notify) {
        endJob(job, result, notify);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#endRule(org.eclipse.core.runtime.jobs.ISchedulingRule)
     */
    public void endRule(ISchedulingRule rule) {
        implicitJobs.end(rule, false);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#find(java.lang.String)
     */
    public Job[] find(Object family) {
        List members = select(family);
        return arraycast!(Job)( members.toArray());
    }

    /**
     * Returns a running or blocked job whose scheduling rule conflicts with the
     * scheduling rule of the given waiting job.  Returns null if there are no
     * conflicting jobs.  A job can only run if there are no running jobs and no blocked
     * jobs whose scheduling rule conflicts with its rule.
     */
    protected InternalJob findBlockingJob(InternalJob waitingJob) {
        if (waitingJob.getRule() is null)
            return null;
        synchronized (lock) {
            if (running.isEmpty())
                return null;
            //check the running jobs
            bool hasBlockedJobs = false;
            for (Iterator it = running.iterator(); it.hasNext();) {
                InternalJob job = cast(InternalJob) it.next();
                if (waitingJob.isConflicting(job))
                    return job;
                if (!hasBlockedJobs)
                    hasBlockedJobs = job.previous() !is null;
            }
            //there are no blocked jobs, so we are done
            if (!hasBlockedJobs)
                return null;
            //check all jobs blocked by running jobs
            for (Iterator it = running.iterator(); it.hasNext();) {
                InternalJob job = cast(InternalJob) it.next();
                while (true) {
                    job = job.previous();
                    if (job is null)
                        break;
                    if (waitingJob.isConflicting(job))
                        return job;
                }
            }
        }
        return null;
    }
    package InternalJob findBlockingJob_package(InternalJob waitingJob) {
        return findBlockingJob(waitingJob);
    }

    public LockManager getLockManager() {
        return lockManager;
    }

    private void initDebugOptions() {
        DEBUG = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_DEBUG_JOBS, false);
        DEBUG_BEGIN_END = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_DEBUG_BEGIN_END, false);
        DEBUG_DEADLOCK = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_DEADLOCK_ERROR, false);
        DEBUG_LOCKS = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_LOCKS, false);
        DEBUG_TIMING = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_DEBUG_JOBS_TIMING, false);
        DEBUG_SHUTDOWN = JobOSGiUtils.getDefault().getBooleanDebugOption(OPTION_SHUTDOWN, false);
    }

    /**
     * Returns whether the job manager is active (has not been shutdown).
     */
    protected bool isActive() {
        return active;
    }
    package bool isActive_package() {
        return isActive();
    }

    /**
     * Returns true if the given job is blocking the execution of a non-system
     * job.
     */
    protected bool isBlocking(InternalJob runningJob) {
        synchronized (lock) {
            // if this job isn't running, it can't be blocking anyone
            if (runningJob.getState_package() !is Job.RUNNING)
                return false;
            // if any job is queued behind this one, it is blocked by it
            InternalJob previous = runningJob.previous();
            while (previous !is null) {
                // ignore jobs of lower priority (higher priority value means lower priority)
                if (previous.getPriority() < runningJob.getPriority()) {
                    if (!previous.isSystem_package())
                        return true;
                    // implicit jobs should interrupt unless they act on behalf of system jobs
                    if (cast(ThreadJob)previous  && (cast(ThreadJob) previous).shouldInterrupt())
                        return true;
                }
                previous = previous.previous();
            }
            // none found
            return false;
        }
    }
    package bool isBlocking_package(InternalJob runningJob) {
        return isBlocking(runningJob);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#isIdle()
     */
    public bool isIdle() {
        synchronized (lock) {
            return running.isEmpty() && waiting.isEmpty();
        }
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#isSuspended()
     */
    public bool isSuspended() {
        synchronized (lock) {
            return suspended;
        }
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.Job#job(org.eclipse.core.runtime.jobs.Job)
     */
    protected void join(InternalJob job) {
        IJobChangeListener listener;
        Semaphore barrier;
        synchronized (lock) {
            int state = job.getState_package();
            if (state is Job.NONE)
                return;
            //don't join a waiting or sleeping job when suspended (deadlock risk)
            if (suspended && state !is Job.RUNNING)
                return;
            //it's an error for a job to join itself
            if (state is Job.RUNNING && job.getThread_package() is Thread.currentThread())
                throw new IllegalStateException("Job attempted to join itself"); //$NON-NLS-1$
            //the semaphore will be released when the job is done
            barrier = new Semaphore(null);
            listener = new class(barrier) JobChangeAdapter {
                Semaphore barrier_;
                this( Semaphore a ){
                    barrier_ = a;
                }
                public void done(IJobChangeEvent event) {
                    barrier_.release();
                }
            };
            job.addJobChangeListener_package(listener);
            //compute set of all jobs that must run before this one
            //add a listener that removes jobs from the blocking set when they finish
        }
        //wait until listener notifies this thread.
        try {
            while (true) {
                //notify hook to service pending syncExecs before falling asleep
                lockManager.aboutToWait(job.getThread_package());
                try {
                    if (barrier.acquire(Long.MAX_VALUE))
                        break;
                } catch (InterruptedException e) {
                    //loop and keep trying
                }
            }
        } finally {
            lockManager.aboutToRelease();
            job.removeJobChangeListener_package(listener);
        }
    }
    package void join_package(InternalJob job) {
        join(job);
    }

    /* (non-Javadoc)
     * @see IJobManager#join(String, IProgressMonitor)
     */
    public void join(Object family_, IProgressMonitor monitor) {
        monitor = monitorFor(monitor);
        IJobChangeListener listener = null;
        Set jobs_;
        int jobCount;
        Job blocking = null;
        synchronized (lock) {
            //don't join a waiting or sleeping job when suspended (deadlock risk)
            int states = suspended ? Job.RUNNING : Job.RUNNING | Job.WAITING | Job.SLEEPING;
            jobs_ = Collections.synchronizedSet(new HashSet(select(family_, states)));
            jobCount = jobs_.size();
            if (jobCount > 0) {
                //if there is only one blocking job, use it in the blockage callback below
                if (jobCount is 1)
                    blocking = cast(Job) jobs_.iterator().next();
                listener = new class(family_, jobs_ )JobChangeAdapter {
                    Object family;
                    Set jobs;
                    this(Object a, Set b){
                        family = a;
                        jobs = b;
                    }
                    public void done(IJobChangeEvent event) {
                        //don't remove from list if job is being rescheduled
                        if (!(cast(JobChangeEvent) event).reschedule)
                            jobs.remove(event.getJob());
                    }

                    //update the list of jobs if new ones are added during the join
                    public void scheduled(IJobChangeEvent event) {
                        //don't add to list if job is being rescheduled
                        if ((cast(JobChangeEvent) event).reschedule)
                            return;
                        Job job = event.getJob();
                        if (job.belongsTo(family))
                            jobs.add(job);
                    }
                };
                addJobChangeListener(listener);
            }
        }
        if (jobCount is 0) {
            //use up the monitor outside synchronized block because monitors call untrusted code
            monitor.beginTask(JobMessages.jobs_blocked0, 1);
            monitor.done();
            return;
        }
        //spin until all jobs are completed
        try {
            monitor.beginTask(JobMessages.jobs_blocked0, jobCount);
            monitor.subTask(NLS.bind(JobMessages.jobs_waitFamSub, Integer.toString(jobCount)));
            reportBlocked(monitor, blocking);
            int jobsLeft;
            int reportedWorkDone = 0;
            while ((jobsLeft = jobs_.size()) > 0) {
                //don't let there be negative work done if new jobs have
                //been added since the join began
                int actualWorkDone = Math.max(0, jobCount - jobsLeft);
                if (reportedWorkDone < actualWorkDone) {
                    monitor.worked(actualWorkDone - reportedWorkDone);
                    reportedWorkDone = actualWorkDone;
                    monitor.subTask(NLS.bind(JobMessages.jobs_waitFamSub, Integer.toString(jobsLeft)));
                }

                if (Thread.interrupted())
                    throw new InterruptedException();
                if (monitor.isCanceled())
                    throw new OperationCanceledException();
                //notify hook to service pending syncExecs before falling asleep
                lockManager.aboutToWait(null);
                Thread.sleep(100);
            }
        } finally {
            lockManager.aboutToRelease();
            removeJobChangeListener(listener);
            reportUnblocked(monitor);
            monitor.done();
        }
    }

    /**
     * Returns a non-null progress monitor instance.  If the monitor is null,
     * returns the default monitor supplied by the progress provider, or a
     * NullProgressMonitor if no default monitor is available.
     */
    private IProgressMonitor monitorFor(IProgressMonitor monitor) {
        if (monitor is null || (cast(NullProgressMonitor)monitor )) {
            if (progressProvider !is null) {
                try {
                    monitor = progressProvider.getDefaultMonitor();
                } catch (Exception e) {
                    String msg = NLS.bind(JobMessages.meta_pluginProblems, JobManager.PI_JOBS);
                    RuntimeLog.log(new Status(IStatus.ERROR, JobManager.PI_JOBS, JobManager.PLUGIN_ERROR, msg, e));
                }
            }
        }

        if (monitor is null)
            return new NullProgressMonitor();
        return monitor;
    }

    /* (non-Javadoc)
     * @see IJobManager#newLock(java.lang.String)
     */
    public ILock newLock() {
        return lockManager.newLock();
    }

    /**
     * Removes and returns the first waiting job in the queue. Returns null if there
     * are no items waiting in the queue.  If an item is removed from the queue,
     * it is moved to the running jobs list.
     */
    private Job nextJob() {
        synchronized (lock) {
            //do nothing if the job manager is suspended
            if (suspended)
                return null;
            //tickle the sleep queue to see if anyone wakes up
            long now = System.currentTimeMillis();
            InternalJob job = sleeping.peek();
            while (job !is null && job.getStartTime() < now) {
                job.setStartTime(now + delayFor(job.getPriority()));
                job.setWaitQueueStamp(waitQueueCounter++);
                changeState(job, Job.WAITING);
                job = sleeping.peek();
            }
            //process the wait queue until we find a job whose rules are satisfied.
            while ((job = waiting.peek()) !is null) {
                InternalJob blocker = findBlockingJob(job);
                if (blocker is null)
                    break;
                //queue this job after the job that's blocking it
                changeState(job, InternalJob.BLOCKED);
                //assert job does not already belong to some other data structure
                Assert.isTrue(job.next() is null);
                Assert.isTrue(job.previous() is null);
                blocker.addLast(job);
            }
            //the job to run must be in the running list before we exit
            //the sync block, otherwise two jobs with conflicting rules could start at once
            if (job !is null) {
                changeState(job, InternalJob.ABOUT_TO_RUN);
                if (JobManager.DEBUG)
                    JobManager.debug_(Format("Starting job: {}", job)); //$NON-NLS-1$
            }
            return cast(Job) job;
        }
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#removeJobListener(org.eclipse.core.runtime.jobs.IJobChangeListener)
     */
    public void removeJobChangeListener(IJobChangeListener listener) {
        jobListeners.remove(listener);
    }

    /**
     * Report to the progress monitor that this thread is blocked, supplying
     * an information message, and if possible the job that is causing the blockage.
     * Important: An invocation of this method MUST be followed eventually be
     * an invocation of reportUnblocked.
     * @param monitor The monitor to report blocking to
     * @param blockingJob The job that is blocking this thread, or <code>null</code>
     * @see #reportUnblocked
     */
    final void reportBlocked(IProgressMonitor monitor, InternalJob blockingJob) {
        if (!(cast(IProgressMonitorWithBlocking)monitor ))
            return;
        IStatus reason;
        if (blockingJob is null || cast(ThreadJob)blockingJob || blockingJob.isSystem_package()) {
            reason = new Status(IStatus.INFO, JobManager.PI_JOBS, 1, JobMessages.jobs_blocked0, null);
        } else {
            String msg = NLS.bind(JobMessages.jobs_blocked1, blockingJob.getName_package());
            reason = new JobStatus(IStatus.INFO, cast(Job) blockingJob, msg);
        }
        (cast(IProgressMonitorWithBlocking) monitor).setBlocked(reason);
    }

    /**
     * Reports that this thread was blocked, but is no longer blocked and is able
     * to proceed.
     * @param monitor The monitor to report unblocking to.
     * @see #reportBlocked
     */
    final void reportUnblocked(IProgressMonitor monitor) {
        if (cast(IProgressMonitorWithBlocking)monitor )
            (cast(IProgressMonitorWithBlocking) monitor).clearBlocked();
    }

    /*(non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#resume()
     */
    public final void resume() {
        synchronized (lock) {
            suspended = false;
            //poke the job pool
            pool.jobQueued();
        }
    }

    /** (non-Javadoc)
     * @deprecated this method should not be used
     * @see org.eclipse.core.runtime.jobs.IJobManager#resume(org.eclipse.core.runtime.jobs.ISchedulingRule)
     */
    public final void resume(ISchedulingRule rule) {
        implicitJobs.resume(rule);
    }

    /**
     * Attempts to immediately start a given job.  Returns true if the job was
     * successfully started, and false if it could not be started immediately
     * due to a currently running job with a conflicting rule.  Listeners will never
     * be notified of jobs that are run in this way.
     */
    protected bool runNow(InternalJob job) {
        synchronized (lock) {
            //cannot start if there is a conflicting job
            if (findBlockingJob(job) !is null)
                return false;
            changeState(job, Job.RUNNING);
            job.setProgressMonitor(new NullProgressMonitor());
            job.run_package(null);
        }
        return true;
    }
    package bool runNow_package(InternalJob job) {
        return runNow(job);
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.Job#schedule(long)
     */
    protected void schedule(InternalJob job, long delay, bool reschedule) {
        if (!active)
            throw new IllegalStateException("Job manager has been shut down."); //$NON-NLS-1$
        Assert.isNotNull(job, "Job is null"); //$NON-NLS-1$
        Assert.isLegal(delay >= 0, "Scheduling delay is negative"); //$NON-NLS-1$
        synchronized (lock) {
            //if the job is already running, set it to be rescheduled when done
            if (job.getState_package() is Job.RUNNING) {
                job.setStartTime(delay);
                return;
            }
            //can't schedule a job that is waiting or sleeping
            if (job.internalGetState() !is Job.NONE)
                return;
            if (JobManager.DEBUG)
                JobManager.debug_(Format("Scheduling job: {}", job)); //$NON-NLS-1$
            //remember that we are about to schedule the job
            //to prevent multiple schedule attempts from succeeding (bug 68452)
            changeState(job, InternalJob.ABOUT_TO_SCHEDULE);
        }
        //notify listeners outside sync block
        jobListeners.scheduled(cast(Job) job, delay, reschedule);
        //schedule the job
        doSchedule(job, delay);
        //call the pool outside sync block to avoid deadlock
        pool.jobQueued();
    }
    package void schedule_package(InternalJob job, long delay, bool reschedule) {
        schedule(job, delay, reschedule);
    }

    /**
     * Adds all family members in the list of jobs to the collection
     */
    private void select(List members, Object family, InternalJob firstJob, int stateMask) {
        if (firstJob is null)
            return;
        InternalJob job = firstJob;
        do {
            //note that job state cannot be NONE at this point
            if ((family is null || job.belongsTo_package(family)) && ((job.getState_package() & stateMask) !is 0))
                members.add(job);
            job = job.previous();
        } while (job !is null && job !is firstJob);
    }

    /**
     * Returns a list of all jobs known to the job manager that belong to the given family.
     */
    private List select(Object family) {
        return select(family, Job.WAITING | Job.SLEEPING | Job.RUNNING);
    }

    /**
     * Returns a list of all jobs known to the job manager that belong to the given
     * family and are in one of the provided states.
     */
    private List select(Object family, int stateMask) {
        List members = new ArrayList();
        synchronized (lock) {
            if ((stateMask & Job.RUNNING) !is 0) {
                for (Iterator it = running.iterator(); it.hasNext();) {
                    select(members, family, cast(InternalJob) it.next(), stateMask);
                }
            }
            if ((stateMask & Job.WAITING) !is 0)
                select(members, family, waiting.peek(), stateMask);
            if ((stateMask & Job.SLEEPING) !is 0)
                select(members, family, sleeping.peek(), stateMask);
        }
        return members;
    }

    /* (non-Javadoc)
     * @see IJobManager#setLockListener(LockListener)
     */
    public void setLockListener(LockListener listener) {
        lockManager.setLockListener(listener);
    }

    /**
     * Changes a job priority.
     */
    protected void setPriority(InternalJob job, int newPriority) {
        synchronized (lock) {
            int oldPriority = job.getPriority();
            if (oldPriority is newPriority)
                return;
            job.internalSetPriority(newPriority);
            //if the job is waiting to run, re-shuffle the queue
            if (job.getState_package() is Job.WAITING) {
                long oldStart = job.getStartTime();
                job.setStartTime(oldStart + (delayFor(newPriority) - delayFor(oldPriority)));
                waiting.resort(job);
            }
        }
    }
    package void setPriority_package(InternalJob job, int newPriority) {
        setPriority(job, newPriority);
    }

    /* (non-Javadoc)
     * @see IJobManager#setProgressProvider(IProgressProvider)
     */
    public void setProgressProvider(ProgressProvider provider) {
        progressProvider = provider;
    }

    /* (non-Javadoc)
     * @see Job#setRule
     */
    public void setRule(InternalJob job, ISchedulingRule rule) {
        synchronized (lock) {
            //cannot change the rule of a job that is already running
            Assert.isLegal(job.getState_package() is Job.NONE);
            validateRule(rule);
            job.internalSetRule(rule);
        }
    }

    /**
     * Puts a job to sleep. Returns true if the job was successfully put to sleep.
     */
    protected bool sleep(InternalJob job) {
        synchronized (lock) {
            switch (job.getState_package()) {
                case Job.RUNNING :
                    //cannot be paused if it is already running (as opposed to ABOUT_TO_RUN)
                    if (job.internalGetState() is Job.RUNNING)
                        return false;
                    //job hasn't started running yet (aboutToRun listener)
                    break;
                case Job.SLEEPING :
                    //update the job wake time
                    job.setStartTime(InternalJob.T_INFINITE);
                    //change state again to re-shuffle the sleep queue
                    changeState(job, Job.SLEEPING);
                    return true;
                case Job.NONE :
                    return true;
                case Job.WAITING :
                    //put the job to sleep
                    break;
                default:
            }
            job.setStartTime(InternalJob.T_INFINITE);
            changeState(job, Job.SLEEPING);
        }
        jobListeners.sleeping(cast(Job) job);
        return true;
    }
    package bool sleep_package(InternalJob job) {
        return sleep(job);
    }

    /* (non-Javadoc)
     * @see IJobManager#sleep(String)
     */
    public void sleep(Object family) {
        //don't synchronize because sleep calls listeners
        for (Iterator it = select(family).iterator(); it.hasNext();) {
            sleep(cast(InternalJob) it.next());
        }
    }

    /**
     * Returns the estimated time in milliseconds before the next job is scheduled
     * to wake up. The result may be negative.  Returns InternalJob.T_INFINITE if
     * there are no sleeping or waiting jobs.
     */
    protected long sleepHint() {
        synchronized (lock) {
            //wait forever if job manager is suspended
            if (suspended)
                return InternalJob.T_INFINITE;
            if (!waiting.isEmpty())
                return 0L;
            //return the anticipated time that the next sleeping job will wake
            InternalJob next = sleeping.peek();
            if (next is null)
                return InternalJob.T_INFINITE;
            return next.getStartTime() - System.currentTimeMillis();
        }
    }
    package long sleepHint_package() {
        return sleepHint();
    }
    /**
     * Returns the next job to be run, or null if no jobs are waiting to run.
     * The worker must call endJob when the job is finished running.
     */
    protected Job startJob() {
        Job job = null;
        while (true) {
            job = nextJob();
            if (job is null)
                return null;
            //must perform this outside sync block because it is third party code
            if (job.shouldRun()) {
                //check for listener veto
                jobListeners.aboutToRun(job);
                //listeners may have canceled or put the job to sleep
                synchronized (lock) {
                    if (job.getState() is Job.RUNNING) {
                        InternalJob internal = job;
                        if (internal.isAboutToRunCanceled()) {
                            internal.setAboutToRunCanceled(false);
                            //fall through and end the job below
                        } else {
                            internal.setProgressMonitor(createMonitor(job));
                            //change from ABOUT_TO_RUN to RUNNING
                            internal.internalSetState(Job.RUNNING);
                            break;
                        }
                    }
                }
            }
            if (job.getState() !is Job.SLEEPING) {
                //job has been vetoed or canceled, so mark it as done
                endJob(job, Status.CANCEL_STATUS, true);
                continue;
            }
        }
        jobListeners.running(job);
        return job;

    }
    package Job startJob_package() {
        return startJob();
    }

    /* non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#suspend()
     */
    public final void suspend() {
        synchronized (lock) {
            suspended = true;
        }
    }

    /** (non-Javadoc)
     * @deprecated this method should not be used
     * @see org.eclipse.core.runtime.jobs.IJobManager#suspend(org.eclipse.core.runtime.jobs.ISchedulingRule, org.eclipse.core.runtime.IProgressMonitor)
     */
    public final void suspend(ISchedulingRule rule, IProgressMonitor monitor) {
        Assert.isNotNull(cast(Object)rule);
        implicitJobs.suspend(rule, monitorFor(monitor));
    }

    /* non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.IJobManager#transferRule()
     */
    public void transferRule(ISchedulingRule rule, Thread destinationThread) {
        implicitJobs.transfer(rule, destinationThread);
    }

    /**
     * Validates that the given scheduling rule obeys the constraints of
     * scheduling rules as described in the <code>ISchedulingRule</code>
     * javadoc specification.
     */
    private void validateRule(ISchedulingRule rule) {
        //null rule always valid
        if (rule is null)
            return;
        initNullRule();
        //contains method must be reflexive
        Assert.isLegal(rule.contains(rule));
        //contains method must return false when given an unknown rule
        Assert.isLegal(!rule.contains(nullRule));
        //isConflicting method must be reflexive
        Assert.isLegal(rule.isConflicting(rule));
        //isConflicting method must return false when given an unknown rule
        Assert.isLegal(!rule.isConflicting(nullRule));
    }

    /* (non-Javadoc)
     * @see Job#wakeUp(long)
     */
    protected void wakeUp(InternalJob job, long delay) {
        Assert.isLegal(delay >= 0, "Scheduling delay is negative"); //$NON-NLS-1$
        synchronized (lock) {
            //cannot wake up if it is not sleeping
            if (job.getState_package() !is Job.SLEEPING)
                return;
            doSchedule(job, delay);
        }
        //call the pool outside sync block to avoid deadlock
        pool.jobQueued();

        //only notify of wake up if immediate
        if (delay is 0)
            jobListeners.awake(cast(Job) job);
    }
    package void wakeUp_package(InternalJob job, long delay) {
        wakeUp(job, delay);
    }

    /* (non-Javadoc)
     * @see IJobFamily#wakeUp(String)
     */
    public void wakeUp(Object family) {
        //don't synchronize because wakeUp calls listeners
        for (Iterator it = select(family).iterator(); it.hasNext();) {
            wakeUp(cast(InternalJob) it.next(), 0L);
        }
    }
}
