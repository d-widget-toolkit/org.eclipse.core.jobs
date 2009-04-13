/*******************************************************************************
 * Copyright (c) 2005, 2007 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.JobOSGiUtils;

import java.lang.all;
import java.util.Set;

// import org.osgi.framework.Bundle;
// import org.osgi.framework.BundleContext;
// import org.osgi.service.packageadmin.PackageAdmin;
// import org.osgi.util.tracker.ServiceTracker;

import org.eclipse.core.runtime.jobs.IJobManager;
// import org.eclipse.osgi.service.debug.DebugOptions;

/**
 * The class contains a set of helper methods for the runtime Jobs plugin.
 * The following utility methods are supplied:
 * - provides access to debug options
 * - provides some bundle discovery functionality
 *
 * The closeServices() method should be called before the plugin is stopped.
 *
 * @since org.eclipse.core.jobs 3.2
 */
class JobOSGiUtils {
//     private ServiceTracker debugTracker = null;
//     private ServiceTracker bundleTracker = null;

    private static /+final+/ JobOSGiUtils singleton;

    /**
     * Accessor for the singleton instance
     * @return The JobOSGiUtils instance
     */
    public static synchronized JobOSGiUtils getDefault() {
        if( singleton is null ){
            singleton = new JobOSGiUtils();
        }
        return singleton;
    }

    /**
     * Private constructor to block instance creation.
     */
    private this() {
//         super();
    }

    void openServices() {
        //FIXME implMissing(__FILE__,__LINE__);
//         BundleContext context = JobActivator.getContext();
//         if (context is null) {
//             if (JobManager.DEBUG)
//                 JobMessages.message("JobsOSGiUtils called before plugin started"); //$NON-NLS-1$
//             return;
//         }
//
//         debugTracker = new ServiceTracker(context, DebugOptions.class.getName(), null);
//         debugTracker.open();
//
//         bundleTracker = new ServiceTracker(context, PackageAdmin.class.getName(), null);
//         bundleTracker.open();
    }

    void closeServices() {
        //FIXME implMissing(__FILE__,__LINE__);
//         if (debugTracker !is null) {
//             debugTracker.close();
//             debugTracker = null;
//         }
//         if (bundleTracker !is null) {
//             bundleTracker.close();
//             bundleTracker = null;
//         }
    }

    public bool getBooleanDebugOption(String option, bool defaultValue) {
        //FIXME implMissing(__FILE__,__LINE__);
        return false;
//         if (debugTracker is null) {
//             if (JobManager.DEBUG)
//                 JobMessages.message("Debug tracker is not set"); //$NON-NLS-1$
//             return defaultValue;
//         }
//         DebugOptions options = (DebugOptions) debugTracker.getService();
//         if (options !is null) {
//             String value = options.getOption(option);
//             if (value !is null)
//                 return value.equalsIgnoreCase("true"); //$NON-NLS-1$
//         }
//         return defaultValue;
    }

    /**
     * Returns the bundle id of the bundle that contains the provided object, or
     * <code>null</code> if the bundle could not be determined.
     */
    public String getBundleId(Object object) {
        //FIXME implMissing(__FILE__,__LINE__);
//         if (bundleTracker is null) {
//             if (JobManager.DEBUG)
//                 JobMessages.message("Bundle tracker is not set"); //$NON-NLS-1$
//             return null;
//         }
//         PackageAdmin packageAdmin = (PackageAdmin) bundleTracker.getService();
//         if (object is null)
//             return null;
//         if (packageAdmin is null)
//             return null;
//         Bundle source = packageAdmin.getBundle(object.getClass());
//         if (source !is null && source.getSymbolicName() !is null)
//             return source.getSymbolicName();
        return null;
    }

    /**
     * Calculates whether the job plugin should set worker threads to be daemon
     * threads.  When workers are daemon threads, the job plugin does not need
     * to be explicitly shut down because the VM can exit while workers are still
     * alive.
     * @return <code>true</code> if all worker threads should be daemon threads,
     * and <code>false</code> otherwise.
     */
    bool useDaemonThreads() {
        //FIXME implMissing(__FILE__,__LINE__);
        return true;
//         BundleContext context = JobActivator.getContext();
//         if (context is null) {
//             //we are running stand-alone, so consult global system property
//             String value = System.getProperty(IJobManager.PROP_USE_DAEMON_THREADS);
//             //default to use daemon threads if property is absent
//             if (value is null)
//                 return true;
//             return "true".equalsIgnoreCase(value); //$NON-NLS-1$
//         }
//         //only use daemon threads if the property is defined
//         final String value = context.getProperty(IJobManager.PROP_USE_DAEMON_THREADS);
//         //if value is absent, don't use daemon threads to maintain legacy behaviour
//         if (value is null)
//             return false;
//         return "true".equalsIgnoreCase(value); //$NON-NLS-1$
    }
}
