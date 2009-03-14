/*******************************************************************************
 * Copyright (c) 2003, 2008 IBM Corporation and others.
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
module org.eclipse.core.runtime.jobs.MultiRule;

import java.lang.all;
import java.util.ArrayList;
import java.util.Set;

import org.eclipse.core.runtime.jobs.ISchedulingRule;

/**
 * A MultiRule is a compound scheduling rule that represents a fixed group of child
 * scheduling rules.  A MultiRule conflicts with another rule if any of its children conflict
 * with that rule.  More formally, a compound rule represents a logical intersection
 * of its child rules with respect to the <code>isConflicting</code> equivalence
 * relation.
 * <p>
 * A MultiRule will never contain other MultiRules as children.  If a MultiRule is provided
 * as a child, its children will be added instead.
 * </p>
 *
 * @since 3.0
 * @noextend This class is not intended to be subclassed by clients.
 */
public class MultiRule : ISchedulingRule {
    private ISchedulingRule[] rules;

    /**
     * Returns a scheduling rule that encompasses all provided rules.  The resulting
     * rule may or may not be an instance of <code>MultiRule</code>.  If all
     * provided rules are <code>null</code> then the result will be
     * <code>null</code>.
     *
     * @param ruleArray An array of scheduling rules, some of which may be <code>null</code>
     * @return a combined scheduling rule, or <code>null</code>
     * @since 3.1
     */
    public static ISchedulingRule combine(ISchedulingRule[] ruleArray) {
        ISchedulingRule result = null;
        for (int i = 0; i < ruleArray.length; i++) {
            if (ruleArray[i] is null)
                continue;
            if (result is null) {
                result = ruleArray[i];
                continue;
            }
            result = combine(result, ruleArray[i]);
        }
        return result;
    }

    /**
     * Returns a scheduling rule that encompasses both provided rules.  The resulting
     * rule may or may not be an instance of <code>MultiRule</code>.  If both
     * provided rules are <code>null</code> then the result will be
     * <code>null</code>.
     *
     * @param rule1 a scheduling rule, or <code>null</code>
     * @param rule2 another scheduling rule, or <code>null</code>
     * @return a combined scheduling rule, or <code>null</code>
     */
    public static ISchedulingRule combine(ISchedulingRule rule1, ISchedulingRule rule2) {
        if (rule1 is rule2)
            return rule1;
        if (rule1 is null)
            return rule2;
        if (rule2 is null)
            return rule1;
        if (rule1.contains(rule2))
            return rule1;
        if (rule2.contains(rule1))
            return rule2;
        MultiRule result = new MultiRule();
        result.rules = [rule1, rule2];
        //make sure we don't end up with nested multi-rules
        if (cast(MultiRule)rule1  || cast(MultiRule)rule2 )
            result.rules = flatten(result.rules);
        return result;
    }

    /*
     * Collapses an array of rules that may contain MultiRules into an
     * array in which no rules are MultiRules.
     */
    private static ISchedulingRule[] flatten(ISchedulingRule[] nestedRules) {
        ArrayList myRules = new ArrayList(nestedRules.length);
        for (int i = 0; i < nestedRules.length; i++) {
            if (cast(MultiRule)nestedRules[i] ) {
                ISchedulingRule[] children = (cast(MultiRule) nestedRules[i]).getChildren();
                for (int j = 0; j < children.length; j++)
                    myRules.add(cast(Object)children[j]);
            } else {
                myRules.add(cast(Object)nestedRules[i]);
            }
        }
        return arraycast!(ISchedulingRule)( myRules.toArray() );
    }

    /**
     * Creates a new scheduling rule that composes a set of nested rules.
     *
     * @param nestedRules the nested rules for this compound rule.
     */
    public this(ISchedulingRule[] nestedRules) {
        this.rules = flatten(nestedRules);
    }

    /**
     * Creates a new scheduling rule with no nested rules. For
     * internal use only.
     */
    private this() {
        //to be invoked only by factory methods
    }

    /**
     * Returns the child rules within this rule.
     * @return the child rules
     */
    public ISchedulingRule[] getChildren() {
        return rules.dup;
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.ISchedulingRule#contains(org.eclipse.core.runtime.jobs.ISchedulingRule)
     */
    public bool contains(ISchedulingRule rule) {
        if (this is rule)
            return true;
        if (cast(MultiRule)rule ) {
            ISchedulingRule[] otherRules = (cast(MultiRule) rule).getChildren();
            //for each child of the target, there must be some child in this rule that contains it.
            for (int other = 0; other < otherRules.length; other++) {
                bool found = false;
                for (int mine = 0; !found && mine < rules.length; mine++)
                    found = rules[mine].contains(otherRules[other]);
                if (!found)
                    return false;
            }
            return true;
        }
        for (int i = 0; i < rules.length; i++)
            if (rules[i].contains(rule))
                return true;
        return false;
    }

    /* (non-Javadoc)
     * @see org.eclipse.core.runtime.jobs.ISchedulingRule#isConflicting(org.eclipse.core.runtime.jobs.ISchedulingRule)
     */
    public bool isConflicting(ISchedulingRule rule) {
        if (this is rule)
            return true;
        if (cast(MultiRule)rule ) {
            ISchedulingRule[] otherRules = (cast(MultiRule) rule).getChildren();
            for (int j = 0; j < otherRules.length; j++)
                for (int i = 0; i < rules.length; i++)
                    if (rules[i].isConflicting(otherRules[j]))
                        return true;
        } else {
            for (int i = 0; i < rules.length; i++)
                if (rules[i].isConflicting(rule))
                    return true;
        }
        return false;
    }

    /*
     * For debugging purposes only.
     */
    public String toString() {
        StringBuffer buffer = new StringBuffer();
        buffer.append("MultiRule["); //$NON-NLS-1$
        int last = rules.length - 1;
        for (int i = 0; i < rules.length; i++) {
            buffer.append(rules[i] ? (cast(Object)rules[i]).toString() : "null" );
            if (i !is last)
                buffer.append(',');
        }
        buffer.append(']');
        return buffer.toString();
    }
}
