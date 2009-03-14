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
module org.eclipse.core.internal.jobs.JobQueue;

import java.lang.all;
import java.util.Set;

import org.eclipse.core.runtime.Assert;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.Status;

import org.eclipse.core.internal.jobs.InternalJob;

/**
 * A linked list based priority queue. Either the elements in the queue must
 * implement Comparable, or a Comparator must be provided.
 */
public class JobQueue {
    /**
     * The dummy entry sits between the head and the tail of the queue.
     * dummy.previous() is the head, and dummy.next() is the tail.
     */
    private final InternalJob dummy;

    /**
     * If true, conflicting jobs will be allowed to overtake others in the
     * queue that have lower priority. If false, higher priority jumps can only
     * move up the queue by overtaking jobs that they don't conflict with.
     */
    private bool allowConflictOvertaking;

    /**
     * Create a new job queue.
     */
    public this(bool allowConflictOvertaking) {
        //compareTo on dummy is never called
        dummy = new class("Queue-Head") InternalJob {//$NON-NLS-1$
            this( String name ){
                super(name);
            }
            public IStatus run(IProgressMonitor m) {
                return Status.OK_STATUS;
            }
        };
        dummy.setNext(dummy);
        dummy.setPrevious(dummy);
        this.allowConflictOvertaking = allowConflictOvertaking;
    }

    /**
     * remove all elements
     */
    public void clear() {
        dummy.setNext(dummy);
        dummy.setPrevious(dummy);
    }

    /**
     * Return and remove the element with highest priority, or null if empty.
     */
    public InternalJob dequeue() {
        InternalJob toRemove = dummy.previous();
        if (toRemove is dummy)
            return null;
        return toRemove.remove();
    }

    /**
     * Adds an item to the queue
     */
    public void enqueue(InternalJob newEntry) {
        //assert new entry is does not already belong to some other data structure
        Assert.isTrue(newEntry.next() is null);
        Assert.isTrue(newEntry.previous() is null);
        InternalJob tail = dummy.next();
        //overtake lower priority jobs. Only overtake conflicting jobs if allowed to
        while (canOvertake(newEntry, tail))
            tail = tail.next();
        //new entry is smaller than tail
        final InternalJob tailPrevious = tail.previous();
        newEntry.setNext(tail);
        newEntry.setPrevious(tailPrevious);
        tailPrevious.setNext(newEntry);
        tail.setPrevious(newEntry);
    }

    /**
     * Returns whether the new entry to overtake the existing queue entry.
     * @param newEntry The entry to be added to the queue
     * @param queueEntry The existing queue entry
     */
    private bool canOvertake(InternalJob newEntry, InternalJob queueEntry) {
        //can never go past the end of the queue
        if (queueEntry is dummy)
            return false;
        //if the new entry was already in the wait queue, ensure it is re-inserted in correct position (bug 211799)
        if (newEntry.getWaitQueueStamp() > 0 && newEntry.getWaitQueueStamp() < queueEntry.getWaitQueueStamp())
            return true;
        //if the new entry has lower priority, there is no need to overtake the existing entry
        if (queueEntry.compareTo(newEntry) >= 0)
            return false;
        //the new entry has higher priority, but only overtake the existing entry if the queue allows it
        return allowConflictOvertaking || !newEntry.isConflicting(queueEntry);
    }

    /**
     * Removes the given element from the queue.
     */
    public void remove(InternalJob toRemove) {
        toRemove.remove();
        //previous of toRemove might now bubble up
    }

    /**
     * The given object has changed priority. Reshuffle the heap until it is
     * valid.
     */
    public void resort(InternalJob entry) {
        remove(entry);
        enqueue(entry);
    }

    /**
     * Returns true if the queue is empty, and false otherwise.
     */
    public bool isEmpty() {
        return dummy.next() is dummy;
    }

    /**
     * Return greatest element without removing it, or null if empty
     */
    public InternalJob peek() {
        return dummy.previous() is dummy ? null : dummy.previous();
    }
}
