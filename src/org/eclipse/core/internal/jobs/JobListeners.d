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
module org.eclipse.core.internal.jobs.JobListeners;

import java.lang.all;

import org.eclipse.core.internal.runtime.RuntimeLog;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.ListenerList;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.IJobChangeEvent;
import org.eclipse.core.runtime.jobs.IJobChangeListener;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.osgi.util.NLS;
import org.eclipse.core.internal.jobs.JobChangeEvent;
import org.eclipse.core.internal.jobs.InternalJob;
import org.eclipse.core.internal.jobs.JobOSGiUtils;
import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.JobMessages;

/**
 * Responsible for notifying all job listeners about job lifecycle events.  Uses a
 * specialized iterator to ensure the complex iteration logic is contained in one place.
 */
class JobListeners {
    interface IListenerDoit {
        public void notify(IJobChangeListener listener, IJobChangeEvent event);
    }

    private const IListenerDoit aboutToRun_;
    private const IListenerDoit awake_;
    private const IListenerDoit done_;
    private const IListenerDoit running_;
    private const IListenerDoit scheduled_;
    private const IListenerDoit sleeping_;
    /**
     * The global job listeners.
     */
    protected const ListenerList global;

    this(){
        aboutToRun_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.aboutToRun(event);
            }
        };
        awake_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.awake(event);
            }
        };
        done_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.done(event);
            }
        };
        running_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.running(event);
            }
        };
        scheduled_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.scheduled(event);
            }
        };
        sleeping_ = new class IListenerDoit {
            public void notify(IJobChangeListener listener, IJobChangeEvent event) {
                listener.sleeping(event);
            }
        };
        global = new ListenerList(ListenerList.IDENTITY);
    }

    /**
     * TODO Could use an instance pool to re-use old event objects
     */
    static JobChangeEvent newEvent(Job job) {
        JobChangeEvent instance = new JobChangeEvent();
        instance.job = job;
        return instance;
    }

    static JobChangeEvent newEvent(Job job, IStatus result) {
        JobChangeEvent instance = new JobChangeEvent();
        instance.job = job;
        instance.result = result;
        return instance;
    }

    static JobChangeEvent newEvent(Job job, long delay) {
        JobChangeEvent instance = new JobChangeEvent();
        instance.job = job;
        instance.delay = delay;
        return instance;
    }

    /**
     * Process the given doit for all global listeners and all local listeners
     * on the given job.
     */
    private void doNotify(IListenerDoit doit, IJobChangeEvent event) {
        //notify all global listeners
        Object[] listeners = global.getListeners();
        int size = listeners.length;
        for (int i = 0; i < size; i++) {
            try {
                if (listeners[i] !is null)
                    doit.notify(cast(IJobChangeListener) listeners[i], event);
            } catch (Exception e) {
                handleException(listeners[i], e);
//             } catch (LinkageError e) {
//                 handleException(listeners[i], e);
            }
        }
        //notify all local listeners
        ListenerList list = (cast(InternalJob) event.getJob()).getListeners();
        listeners = list is null ? null : list.getListeners();
        if (listeners is null)
            return;
        size = listeners.length;
        for (int i = 0; i < size; i++) {
            try {
                if (listeners[i] !is null)
                    doit.notify(cast(IJobChangeListener) listeners[i], event);
            } catch (Exception e) {
                handleException(listeners[i], e);
//             } catch (LinkageError e) {
//                 handleException(listeners[i], e);
            }
        }
    }

    private void handleException(Object listener, Exception e) {
        //this code is roughly copied from InternalPlatform.run(ISafeRunnable),
        //but in-lined here for performance reasons
        if (cast(OperationCanceledException)e )
            return;
        String pluginId = JobOSGiUtils.getDefault().getBundleId(listener);
        if (pluginId is null)
            pluginId = JobManager.PI_JOBS;
        String message = NLS.bind(JobMessages.meta_pluginProblems, pluginId);
        RuntimeLog.log(new Status(IStatus.ERROR, pluginId, JobManager.PLUGIN_ERROR, message, e));
    }

    public void add(IJobChangeListener listener) {
        global.add(cast(Object)listener);
    }

    public void remove(IJobChangeListener listener) {
        global.remove(cast(Object)listener);
    }

    public void aboutToRun(Job job) {
        doNotify(aboutToRun_, newEvent(job));
    }

    public void awake(Job job) {
        doNotify(awake_, newEvent(job));
    }

    public void done(Job job, IStatus result, bool reschedule) {
        JobChangeEvent event = newEvent(job, result);
        event.reschedule = reschedule;
        doNotify(done_, event);
    }

    public void running(Job job) {
        doNotify(running_, newEvent(job));
    }

    public void scheduled(Job job, long delay, bool reschedule) {
        JobChangeEvent event = newEvent(job, delay);
        event.reschedule = reschedule;
        doNotify(scheduled_, event);
    }

    public void sleeping(Job job) {
        doNotify(sleeping_, newEvent(job));
    }
}
