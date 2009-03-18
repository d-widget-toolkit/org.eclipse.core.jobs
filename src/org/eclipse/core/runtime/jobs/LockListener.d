/*******************************************************************************
 * Copyright (c) 2004, 2006 IBM Corporation and others.
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
module org.eclipse.core.runtime.jobs.LockListener;

import java.lang.Thread;
import java.lang.all;
import java.util.Set;

import org.eclipse.core.internal.jobs.JobManager;
import org.eclipse.core.internal.jobs.LockManager;
import org.eclipse.core.runtime.jobs.Job;

/**
 * A lock listener is notified whenever a thread is about to wait
 * on a lock, and when a thread is about to release a lock.
 * <p>
 * This class is for internal use by the platform-related plug-ins.
 * Clients outside of the base platform should not reference or subclass this class.
 * </p>
 *
 * @see IJobManager#setLockListener(LockListener)
 * @since 3.0
 */
public class LockListener {
    private const LockManager manager;

    public this(){
        manager = (cast(JobManager)Job.getJobManager()).getLockManager();
    }

    /**
     * Notification that a thread is about to block on an attempt to acquire a lock.
     * Returns whether the thread should be granted immediate access to the lock.
     * <p>
     * This default implementation always returns <code>false</code>.
     * Subclasses may override.
     *
     * @param lockOwner the thread that currently owns the lock this thread is
     * waiting for, or <code>null</code> if unknown.
     * @return <code>true</code> if the thread should be granted immediate access,
     * and <code>false</code> if it should wait for the lock to be available
     */
    public bool aboutToWait(Thread lockOwner) {
        return false;
    }

    /**
     * Notification that a thread is about to release a lock.
     * <p>
     * This default implementation does nothing. Subclasses may override.
     */
    public void aboutToRelease() {
        //do nothing
    }

    /**
     * Returns whether this thread currently owns any locks
     * @return <code>true</code> if this thread owns any locks, and
     * <code>false</code> otherwise.
     */
    protected final bool isLockOwnerThread() {
        return manager.isLockOwner();
    }
}
