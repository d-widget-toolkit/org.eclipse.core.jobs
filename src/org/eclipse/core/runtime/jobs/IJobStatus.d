/*******************************************************************************
 * Copyright (c) 2004, 2008 IBM Corporation and others.
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
module org.eclipse.core.runtime.jobs.IJobStatus;

import java.lang.all;

import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.jobs.Job;

/**
 * Represents status relating to the execution of jobs.
 *
 * @see org.eclipse.core.runtime.IStatus
 * @noimplement This interface is not intended to be implemented by clients.
 */
public interface IJobStatus : IStatus {
    /**
     * Returns the job associated with this status.
     *
     * @return the job associated with this status
     */
    public Job getJob();
}
