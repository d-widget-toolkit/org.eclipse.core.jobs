/**********************************************************************
 * Copyright (c) 2005, 2006 IBM Corporation and others. All rights reserved.   This
 * program and the accompanying materials are made available under the terms of
 * the Eclipse Public License v1.0 which accompanies this distribution, and is
 * available at http://www.eclipse.org/legal/epl-v10.html
 *
 * Contributors:
 * IBM - Initial API and implementation
 * Port to the D programming language:
 *     Frank Benoit <benoit@tionex.de>
 **********************************************************************/
module org.eclipse.core.internal.jobs.JobMessages;

import java.lang.Thread;
import tango.time.WallClock;
import tango.text.convert.TimeStamp;

import java.lang.all;

import org.eclipse.osgi.util.NLS;

/**
 * Job plugin message catalog
 */
public class JobMessages : NLS {
    private static const String BUNDLE_NAME = "org.eclipse.core.internal.jobs.messages"; //$NON-NLS-1$

    // Job Manager and Locks
    public static String jobs_blocked0 = "The user operation is waiting for background work to complete.";
    public static String jobs_blocked1 = "The user operation is waiting for \"{0}\" to complete.";
    public static String jobs_internalError = "An internal error occured during: \"{0}\".";
    public static String jobs_waitFamSub =  "{0} work item(s) left.";

    // metadata
    public static String meta_pluginProblems = "Problems occured when invoking code from plug-in: \"{0}\".";

//     static this() {
//         // load message values from bundle file
//         reloadMessages();
//     }

    public static void reloadMessages() {
        implMissing(__FILE__,__LINE__);
//         NLS.initializeMessages(BUNDLE_NAME, import(BUNDLE_NAME~".properties"));
    }

    /**
     * Print a debug message to the console.
     * Pre-pend the message with the current date and the name of the current thread.
     */
    public static void message(String message) {
        StringBuffer buffer = new StringBuffer();
        char[30] buf;
        buffer.append(tango.text.convert.TimeStamp.format( buf, WallClock.now()));
        buffer.append(" - ["); //$NON-NLS-1$
        buffer.append(Thread.currentThread().getName());
        buffer.append("] "); //$NON-NLS-1$
        buffer.append(message);
        getDwtLogger.info( __FILE__, __LINE__, buffer.toString());
    }
}
