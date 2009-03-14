/*******************************************************************************
 * Copyright (c) 2000, 2006 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.ObjectMap;

import java.lang.all;
import java.util.Collections;
import java.util.Collection;
import java.util.Iterator;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;
import java.util.HashSet;
import org.eclipse.core.internal.jobs.StringPool;

/**
 * A specialized map implementation that is optimized for a small set of object
 * keys.
 *
 * Implemented as a single array that alternates keys and values.
 *
 * Note: This class is copied from org.eclipse.core.resources
 */
public class ObjectMap : Map {
    // 8 attribute keys, 8 attribute values
    protected static const int DEFAULT_SIZE = 16;
    protected static const int GROW_SIZE = 10;
    protected int count = 0;
    protected Object[] elements = null;

    /**
     * Creates a new object map.
     *
     * @param initialCapacity
     *                  The initial number of elements that will fit in the map.
     */
    public this(int initialCapacity) {
        if (initialCapacity > 0)
            elements = new Object[Math.max(initialCapacity * 2, 0)];
    }

    /**
     * Creates a new object map of the same size as the given map and populate
     * it with the key/attribute pairs found in the map.
     *
     * @param map
     *                  The entries in the given map will be added to the new map.
     */
    public this(Map map) {
        this(map.size());
        putAll(map);
    }

    /**
     * @see Map#clear()
     */
    public void clear() {
        elements = null;
        count = 0;
    }

    /**
     * @see java.lang.Object#clone()
     */
    public Object clone() {
        return new ObjectMap(this);
    }

    /**
     * @see Map#containsKey(java.lang.Object)
     */
    public bool containsKey(Object key) {
        if (elements is null || count is 0)
            return false;
        for (int i = 0; i < elements.length; i = i + 2)
            if (elements[i] !is null && elements[i].opEquals(key))
                return true;
        return false;
    }
    public bool containsKey(String key) {
        return containsKey(stringcast(key));
    }
    /**
     * @see Map#containsValue(java.lang.Object)
     */
    public bool containsValue(Object value) {
        if (elements is null || count is 0)
            return false;
        for (int i = 1; i < elements.length; i = i + 2)
            if (elements[i] !is null && elements[i].opEquals(value))
                return true;
        return false;
    }

    /**
     * @see Map#entrySet()
     *
     * Note: This implementation does not conform properly to the
     * specification in the Map interface. The returned collection will not
     * be bound to this map and will not remain in sync with this map.
     */
    public Set entrySet() {
        return count is 0 ? Collections.EMPTY_SET : toHashMap().entrySet();
    }

    /**
     * @see Object#equals(java.lang.Object)
     */
    public override int opEquals(Object o) {
        if (!(cast(Map)o ))
            return false;
        Map other = cast(Map) o;
        //must be same size
        if (count !is other.size())
            return false;
        //keysets must be equal
        if (!(cast(Object)keySet()).opEquals(cast(Object)other.keySet()))
            return false;
        //values for each key must be equal
        for (int i = 0; i < elements.length; i = i + 2) {
            if (elements[i] !is null && (!elements[i + 1].opEquals(other.get(elements[i]))))
                return false;
        }
        return true;
    }

    /**
     * @see Map#get(java.lang.Object)
     */
    public Object get(Object key) {
        if (elements is null || count is 0)
            return null;
        for (int i = 0; i < elements.length; i = i + 2)
            if (elements[i] !is null && elements[i].opEquals(key))
                return elements[i + 1];
        return null;
    }
    public Object get(String key) {
        return get(stringcast(key));
    }

    /**
     * The capacity of the map has been exceeded, grow the array by GROW_SIZE to
     * accomodate more entries.
     */
    protected void grow() {
        Object[] expanded = new Object[elements.length + GROW_SIZE];
        System.arraycopy(elements, 0, expanded, 0, elements.length);
        elements = expanded;
    }

    /**
     * @see Object#hashCode()
     */
    public override hash_t toHash() {
        int hash = 0;
        for (int i = 0; i < elements.length; i = i + 2) {
            if (elements[i] !is null) {
                hash += elements[i].toHash();
            }
        }
        return hash;
    }

    /**
     * @see Map#isEmpty()
     */
    public bool isEmpty() {
        return count is 0;
    }

    /**
     * Returns all keys in this table as an array.
     */
    public String[] keys() {
        String[] result = new String[count];
        int next = 0;
        for (int i = 0; i < elements.length; i = i + 2)
            if (elements[i] !is null)
                result[next++] = stringcast( elements[i] );
        return result;
    }

    /**
     * @see Map#keySet()
     *
     * Note: This implementation does not conform properly to the
     * specification in the Map interface. The returned collection will not
     * be bound to this map and will not remain in sync with this map.
     */
    public Set keySet() {
        Set result = new HashSet(size());
        for (int i = 0; i < elements.length; i = i + 2) {
            if (elements[i] !is null) {
                result.add(elements[i]);
            }
        }
        return result;
    }

    /**
     * @see Map#put(java.lang.Object, java.lang.Object)
     */
    public Object put(Object key, Object value) {
        if (key is null)
            throw new NullPointerException();
        if (value is null)
            return remove(key);

        // handle the case where we don't have any attributes yet
        if (elements is null)
            elements = new Object[DEFAULT_SIZE];
        if (count is 0) {
            elements[0] = key;
            elements[1] = value;
            count++;
            return null;
        }

        int emptyIndex = -1;
        // replace existing value if it exists
        for (int i = 0; i < elements.length; i += 2) {
            if (elements[i] !is null) {
                if (elements[i].opEquals(key)) {
                    Object oldValue = elements[i + 1];
                    elements[i + 1] = value;
                    return oldValue;
                }
            } else if (emptyIndex is -1) {
                // keep track of the first empty index
                emptyIndex = i;
            }
        }
        // this will put the emptyIndex greater than the size but
        // that's ok because we will grow first.
        if (emptyIndex is -1)
            emptyIndex = count * 2;

        // otherwise add it to the list of elements.
        // grow if necessary
        if (elements.length <= (count * 2))
            grow();
        elements[emptyIndex] = key;
        elements[emptyIndex + 1] = value;
        count++;
        return null;
    }
    public Object put(String key, Object value) {
        return put( stringcast(key), value );
    }
    public Object put(Object key, String value) {
        return put( key, stringcast(value) );
    }
    public Object put(String key, String value) {
        return put( stringcast(key), stringcast(value) );
    }

    /**
     * @see Map#putAll(java.util.Map)
     */
    public void putAll(Map map) {
        for (Iterator i = map.keySet().iterator(); i.hasNext();) {
            Object key = i.next();
            Object value = map.get(key);
            put(key, value);
        }
    }

    /**
     * @see Map#remove(java.lang.Object)
     */
    public Object remove(Object key) {
        if (elements is null || count is 0)
            return null;
        for (int i = 0; i < elements.length; i = i + 2) {
            if (elements[i] !is null && elements[i].opEquals(key)) {
                elements[i] = null;
                Object result = elements[i + 1];
                elements[i + 1] = null;
                count--;
                return result;
            }
        }
        return null;
    }
    public Object remove(String key) {
        return remove( stringcast(key));
    }

    /* (non-Javadoc
     * Method declared on IStringPoolParticipant
     */
    public void shareStrings(StringPool set) {
        //copy elements for thread safety
        Object[] array = elements;
        if (array is null)
            return;
        for (int i = 0; i < array.length; i++) {
            Object o = array[i];
            if (cast(ArrayWrapperString)o )
                array[i] = stringcast(set.add(stringcast( o)));
        }
    }

    /**
     * @see Map#size()
     */
    public int size() {
        return count;
    }

    /**
     * Creates a new hash map with the same contents as this map.
     */
    private HashMap toHashMap() {
        HashMap result = new HashMap(size());
        for (int i = 0; i < elements.length; i = i + 2) {
            if (elements[i] !is null) {
                result.put(elements[i], elements[i + 1]);
            }
        }
        return result;
    }

    /**
     * @see Map#values()
     *
     * Note: This implementation does not conform properly to the
     * specification in the Map interface. The returned collection will not
     * be bound to this map and will not remain in sync with this map.
     */
    public Collection values() {
        Set result = new HashSet(size());
        for (int i = 1; i < elements.length; i = i + 2) {
            if (elements[i] !is null) {
                result.add(elements[i]);
            }
        }
        return result;
    }

    public int opApply (int delegate(ref Object value) dg){
        implMissing(__FILE__, __LINE__ );
        return 0;
    }
    public int opApply (int delegate(ref Object key, ref Object value) dg){
        implMissing(__FILE__, __LINE__ );
        return 0;
    }

}
