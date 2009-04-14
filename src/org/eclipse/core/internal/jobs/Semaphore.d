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
module org.eclipse.core.internal.jobs.Semaphore;

import java.lang.Thread;
import tango.core.sync.Mutex;
import tango.core.sync.Condition;
import java.lang.all;

public class Semaphore {
    protected long notifications;
    protected Thread runnable;

    private Mutex mutex;
    private Condition condition;

    public this(Thread runnable) {
        mutex = new Mutex;
        condition = new Condition(mutex);
        this.runnable = runnable;
        notifications = 0;
    }

    /**
     * Attempts to acquire this semaphore.  Returns true if it was successfully acquired,
     * and false otherwise.
     */
    public bool acquire(long delay) {
        synchronized(mutex){
            if (Thread.interrupted())
                throw new InterruptedException();
            long start = System.currentTimeMillis();
            long timeLeft = delay;
            while (true) {
                if (notifications > 0) {
                    notifications--;
                    return true;
                }
                if (timeLeft <= 0)
                    return false;
                condition.wait(timeLeft/1000.0f);
                timeLeft = start + delay - System.currentTimeMillis();
            }
        }
    }

    public override int opEquals(Object obj) {
        return (runnable is (cast(Semaphore) obj).runnable);
    }

    public override hash_t toHash() {
        return runnable is null ? 0 : (cast(Object)runnable).toHash();
    }

    public void release() {
        synchronized( mutex ){
            notifications++;
            condition.notifyAll();
        }
    }

    // for debug only
    public String toString() {
        return Format("Semaphore({})", cast(Object) runnable ); //$NON-NLS-1$ //$NON-NLS-2$
    }
}
