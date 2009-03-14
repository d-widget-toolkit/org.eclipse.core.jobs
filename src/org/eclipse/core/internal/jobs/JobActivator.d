/*******************************************************************************
 * Copyright (c) 2005, 2006 IBM Corporation and others.
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
module org.eclipse.core.internal.jobs.JobActivator;

import java.lang.all;
import java.util.Set;

// import org.osgi.framework.BundleActivator;
// import org.osgi.framework.BundleContext;
// import org.osgi.framework.ServiceRegistration;

import org.eclipse.core.runtime.jobs.IJobManager;

/**
 * The Jobs plugin class.
 */
public class JobActivator /+: BundleActivator+/ {

    /**
     * Eclipse property. Set to <code>false</code> to avoid registering JobManager
     * as an OSGi service.
     */
    private static const String PROP_REGISTER_JOB_SERVICE = "eclipse.service.jobs"; //$NON-NLS-1$
/++
    /**
     * The bundle associated this plug-in
     */
    private static BundleContext bundleContext;

    /**
     * This plugin provides a JobManager service.
     */
    private ServiceRegistration jobManagerService = null;

    /**
     * This method is called upon plug-in activation
     */
    public void start(BundleContext context) throws Exception {
        bundleContext = context;
        JobOSGiUtils.getDefault().openServices();

        bool shouldRegister = !"false".equalsIgnoreCase(context.getProperty(PROP_REGISTER_JOB_SERVICE)); //$NON-NLS-1$
        if (shouldRegister)
            registerServices();
    }

    /**
     * This method is called when the plug-in is stopped
     */
    public void stop(BundleContext context) throws Exception {
        unregisterServices();
        JobManager.shutdown();
        JobOSGiUtils.getDefault().closeServices();
        bundleContext = null;
    }

    static BundleContext getContext() {
        return bundleContext;
    }

    private void registerServices() {
        jobManagerService = bundleContext.registerService(IJobManager.class.getName(), JobManager.getInstance(), new Hashtable());
    }

    private void unregisterServices() {
        if (jobManagerService !is null) {
            jobManagerService.unregister();
            jobManagerService = null;
        }
    }
++/
}
