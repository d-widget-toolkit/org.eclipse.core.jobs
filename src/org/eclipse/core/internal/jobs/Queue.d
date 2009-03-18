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
module org.eclipse.core.internal.jobs.Queue;

import java.lang.all;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Set;

/**
 * A Queue of objects.
 */
public class Queue {
    protected Object[] elements_;
    protected int head;
    protected bool reuse;
    protected int tail;

    public this() {
        this(20, false);
    }

    /**
     * The parameter reuse indicates what do you want to happen with
     * the object reference when you remove it from the queue. If
     * reuse is false the queue no longer holds a reference to the
     * object when it is removed. If reuse is true you can use the
     * method getNextAvailableObject to get an used object, set its
     * new values and add it again to the queue.
     */
    public this(int size, bool reuse) {
        elements_ = new Object[size];
        head = tail = 0;
        this.reuse = reuse;
    }

    /**
     * Adds an object to the tail of the queue.
     */
    public void enqueue(Object element) {
        int newTail = increment(tail);
        if (newTail is head) {
            grow();
            newTail = tail + 1;
        }
        elements_[tail] = element;
        tail = newTail;
    }

    /**
     * This method does not affect the queue itself. It is only a
     * helper to decrement an index in the queue.
     */
    public int decrement(int index) {
        return (index is 0) ? (elements_.length - 1) : index - 1;
    }

    public Iterator elements() {
        /**/
        if (isEmpty())
            return (new ArrayList(0)).iterator();

        /* if head < tail we can use the same array */
        if (head <= tail)
            return Arrays.asList(elements_).iterator();

        /* otherwise we need to create a new array */
        Object[] newElements = new Object[size()];
        int end = (elements_.length - head);
        System.arraycopy(elements_, head, newElements, 0, end);
        System.arraycopy(elements_, 0, newElements, end, tail);
        return Arrays.asList(newElements).iterator();
    }

    public Object get(Object o) {
        int index = head;
        while (index !is tail) {
            if (elements_[index].opEquals(o))
                return elements_[index];
            index = increment(index);
        }
        return null;
    }

    /**
     * Removes the given object from the queue. Shifts the underlying array.
     */
    public bool remove(Object o) {
        int index = head;
        //find the object to remove
        while (index !is tail) {
            if (elements_[index].opEquals(o))
                break;
            index = increment(index);
        }
        //if element wasn't found, return
        if (index is tail)
            return false;
        //store a reference to it (needed for reuse of objects)
        Object toRemove = elements_[index];
        int nextIndex = -1;
        while (index !is tail) {
            nextIndex = increment(index);
            if (nextIndex !is tail)
                elements_[index] = elements_[nextIndex];

            index = nextIndex;
        }
        //decrement tail
        tail = decrement(tail);

        //if objects are reused, transfer the reference that is removed to the end of the queue
        //otherwise set the element after the last one to null (to avoid duplicate references)
        elements_[tail] = reuse ? toRemove : null;
        return true;
    }

    protected void grow() {
        int newSize = cast(int) (elements_.length * 1.5);
        Object[] newElements = new Object[newSize];
        if (tail >= head)
            System.arraycopy(elements_, head, newElements, head, size());
        else {
            int newHead = newSize - (elements_.length - head);
            System.arraycopy(elements_, 0, newElements, 0, tail + 1);
            System.arraycopy(elements_, head, newElements, newHead, (newSize - newHead));
            head = newHead;
        }
        elements_ = newElements;
    }

    /**
     * This method does not affect the queue itself. It is only a
     * helper to increment an index in the queue.
     */
    public int increment(int index) {
        return (index is (elements_.length - 1)) ? 0 : index + 1;
    }

    public bool isEmpty() {
        return tail is head;
    }

    public Object peek() {
        return elements_[head];
    }

    /**
     * Removes an returns the item at the head of the queue.
     */
    public Object dequeue() {
        if (isEmpty())
            return null;
        Object result = peek();
        if (!reuse)
            elements_[head] = null;
        head = increment(head);
        return result;
    }

    public int size() {
        return tail > head ? (tail - head) : ((elements_.length - head) + tail);
    }

    public String toString() {
        StringBuffer sb = new StringBuffer();
        sb.append("["); //$NON-NLS-1$
        if (!isEmpty()) {
            Iterator it = elements();
            while (true) {
                sb.append(Format("{}",it.next()));
                if (it.hasNext())
                    sb.append(", "); //$NON-NLS-1$
                else
                    break;
            }
        }
        sb.append("]"); //$NON-NLS-1$
        return sb.toString();
    }
}
