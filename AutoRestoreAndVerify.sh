#!/bin/bash
#
# AutoRestoreAndVerify.sh
#
# ------------------------------------------------------------------------------
# 20170831 - Changelog moved to bottom of script.
# ------------------------------------------------------------------------------
#
# BSD 2-Clause License
#
# Copyright (c) 2017-2023, William A. Arlofski waa-at-revpol-dot-com
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
# 1.  Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#
# 2.  Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# ------------------------------------------------------------------------------

# Set some variables
# ------------------
bcbin="/opt/bacula/bin/bconsole"
bccfg="/opt/bacula/etc/bconsole.conf"
cleanup="yes"  # Currently not used at the end... Too dangerous

# --------------------------------------------------
# Nothing should need to be modified below this line
# --------------------------------------------------

# ============================================================================================================
# -----------------------------------
# Example Catalog Backup Job snippet:
# -----------------------------------
#
# Job {
#   Name = Catalog
#   Client = bacula-fd
#   JobDefs = Defaults-To-Speedy
#   FileSet = Catalog
#   Level = Full
#   Schedule = Catalog
#   Priority = 20
#   WriteBootstrap = "/opt/bacula/bsr/%n_%i.bsr"
#
#   RunScript {
#     RunsWhen = before
#     RunsOnClient = no
#     FailJobOnError = yes
#     # waa - 20150215 - One custom RunsBefore script to dump a time-stamped
#     #                  bacula database file and then remove old copies
#     # --------------------------------------------------------------------
#     Command = "/opt/bacula/scripts/bacula_pgsqlbackup.sh"
#   }
#
# # waa - 20170502 - Run an Auto-restore and then run three Verify
# #                  jobs: VolumeToCatalog, DiskToCatalog, and Data
# # ---------------------------------------------------------------
#   RunScript {
#     RunsWhen = after
#     RunsOnClient = no
#     RunsOnFailure = no
#
#     # Call _this_ script and pass the current backup job jobid, client, jobname, and fileset
#     # --------------------------------------------------------------------------------------
#     Command = "/opt/bacula/scripts/AutoRestoreAndVerify.sh %i %c %n %f"
#   }
# }
#
# -------------------------------------------------------------------------
# Example "special" RestoreJob with same priority as our Catalog Backup Job
# -------------------------------------------------------------------------
# Job {
#   Name = RestoreCatalog
#   Type = Restore
#   Messages = Standard
#   Where = /tmp/bacula-auto_restores
#   MaximumConcurrentJobs = 10
#   WriteBootstrap = "/opt/bacula/bsr/%c_%n_%i.bsr"
#   Priority = 20     # waa - 20170802 - Set to match the same priority as the Catalog job to prevent dead lock
#   # I have created a special Storage, Client, FileSet and Pool, each called "None"
#   # for use in Copy/migration jobs, or in this case for my special Catalog Restore Job
#   # ----------------------------------------------------------------------------------
#   Storage  = None   # waa - 20150715 - Is never used, but required by Bacula config parser
#   Client   = None   # waa - 20131020 - Is never used, but required by Bacula config parser
#   FileSet  = None   # waa - 20131020 - Is never used, but required by Bacula config parser
#   Pool     = None   # waa - 20131020 - Is never used, but required by Bacula config parser
# }
#
# -----------------------------------------------------------------
# Example Verify_Catalog Verify Job which is called by this script:
# -----------------------------------------------------------------
# Job {
#   Name = Verify_Catalog
#   Enabled = yes
#   Type = Verify
#   Priority = 20               # Must be same as the Catalog job so this will not be heled "waiting for higher priorty..."
#   Level = VolumeToCatalog     # Place holder. Verify Type/Level will be specified on the command line.
#   JobDefs = Defaults
#   Client = None               # Resources named 'None' here must exist in your config. They can be any already
#   FileSet = None              # existing resource. They will be overridden on the command line.
#   Pool = None
#   Storage = speedy-file       # Must be correct, or specified on the command line.
#   Schedule = Manual           # to call this verify job. See the Catalog job and this script for examples.
#   MaximumConcurrentJobs = 5
#   AllowDuplicateJobs = yes
# }
# ============================================================================================================

# -------------------------------------------------------------------------
# When called from a RunScript{} (RunsWhen = After) in a Backup Job, we get
# %i (jobid), %c (client), %n (jobname), and %f (fileset) as $1, $2, $3, $4
# -------------------------------------------------------------------------

# Simple test to verify at least four command line arguments were supplied
# ------------------------------------------------------------------------
if [ $# -lt 4 ]; then
  echo -e "\nUse: $0 <jobid> <client> <jobname> <fileset>"
  echo -e "Command line received: $0 $@\n"
  exit 1
fi

# Verify that the bconsole config file exists
# -------------------------------------------
if [ ! -e ${bccfg} ]; then
  echo -e "\nThe bconsole configuration file does not seem to be '${bccfg}'."
  echo -e "Please check the setting for the variable 'bccfg'.\n"
  exit 1
fi

# Verify that the bconsole binary exists and is executable
# --------------------------------------------------------
if [ ! -x ${bcbin} ]; then
  echo -e "\nThe bconsole binary does not seem to be '${bcbin}', or it is not executable."
  echo -e "Please check the setting for the variable 'bcbin'.\n"
  exit 1
fi

# Create the temporary restore directory including the Job name
# -------------------------------------------------------------
restoredir=$(mktemp -q -d /mnt/iscsi_backups/bacula/bacula-auto_restores-$3-XXXX)

# Start the Restore job and get its jobid so we can wait for it to finish
# Restore jobs currently do not accept the "priority" option on the command line!
# So, we need to create a special "RestoreCatalog" restore job resource and set its priority=20 (Same as our Catalog job)
# so it can be triggered in a RunScript (RunsWhen = After) and not be held up waiting for: "higher priority jobs to finish"
# The "higher priority Job" being the actual Catalog backup job. We would end up in a deadlock in this case.
# -------------------------------------------------------------------------------------------------------------------------
echo "Starting restore of backup job \"$3\" (jobid $1) to restore directory \"${restoredir}\""
status=$(echo "restore jobid=$1 client=$2 restoreclient=$2 restorejob=RestoreCatalog \
               where=${restoredir} comment=\"AutoRestore of job: $3 to ${restoredir}\" all done yes" \
               | ${bcbin} -c ${bccfg})

# Get the jobid of the Restore job and print it
# ---------------------------------------------
jobid=$(echo "${status}" | grep "^Job queued" | cut -d'=' -f2)
echo "Restore Job's jobid=${jobid}"

# Wait for the Restore job to finish, then start the VolumeToCatalog Verify job
# -----------------------------------------------------------------------------
echo "Queueing VolumeToCatalog verify of job \"$3\", (jobid $1)"
status=$(echo -e "wait jobid=${jobid} \n run job=Verify_Catalog jobid=$1 client=$2 level=VolumeToCatalog \
                 comment=\"VolumeToCatalog of job: $3\" yes" | ${bcbin} -c ${bccfg})

# Get the jobid of the VolumeToCatalog job and print it
# -----------------------------------------------------
jobid=$(echo "${status}" | grep "^Job queued" | cut -d'=' -f2)
echo "VolumeToCatalog Job's jobid=${jobid}"

# Wait for the VolumeToCatalog Verify job to finish, then start the DiskToCatalog Verify job
# NOTE: the "fileset =" is required in the named job resource, or on the command line!
# ------------------------------------------------------------------------------------------
echo "Queueing DiskToCatalog verify of job \"$3\", (jobid $1)"
status=$(echo -e "wait jobid=${jobid} \n run job=Verify_Catalog jobid=$1 client=$2 fileset=$4 level=DiskToCatalog \
                  comment=\"DiskToCatalog of job: $3\" yes" | ${bcbin} -c ${bccfg})

# Get the jobid of the DiskToCatalog job and print it
# ---------------------------------------------------
jobid=$(echo "${status}" | grep "^Job queued" | cut -d'=' -f2)
echo "DiskToCatalog Job's jobid=${jobid}"

# Wait for the DiskToCatalog Verify job to finish, then start the Level=Data Verify job
# NOTE: the "fileset =" is required in the named job resource, or on the command line!
# -------------------------------------------------------------------------------------
echo "Queueing DATA verify of job \"$3\", (jobid $1)"
status=$(echo -e "wait jobid=${jobid} \n run job=Verify_Catalog jobid=$1 client=$2 fileset=$4 level=Data \
                  comment=\"Data Verify of job: $3\" yes" | ${bcbin} -c ${bccfg})

# Get the jobid of the DATA Verification job and print it
# -------------------------------------------------------
jobid=$(echo "${status}" | grep "^Job queued" | cut -d'=' -f2)
echo "Data Verify Job's jobid=${jobid}"

# Wait for the DATA Verify job to finish
# --------------------------------------
echo "Waiting for DATA verify job (jobid ${jobid}) to finish..."
status=$(echo -e "wait jobid=${jobid} \n" | ${bcbin} -c ${bccfg})

# Delete the temporary restore directory?
# ---------------------------------------
# if [ "${cleanup}" = "yes" ]; then
#   echo "Deleting temporary restore directory '${restoredir}'..."
#   rm -rf ${restoredir}

echo -e "\nFinished...\n"
# -------------
# End of script
# -------------

# ----------
# Change Log
# ----------
# ----------------------------
# William A. Arlofski
# waa@protonmail.com
# ----------------------------
#
# 20170831 - Initial release
#            Automatically restore a backup job, then run all three
#            verification jobs against it 
#          - May be run manully or triggered in a RunScript of a job
# 20170902 - Added some more logging
# 20190129 - Changed the 'restoredir' variable to be randomly created using the
#            mktemp utility
#          - No longer attempt to "rm -rf" a statically named restore directory
# 20230304 - Added Job name to the 'restoredir' variable
# 20230614 - Minor clean up before releasing on Github.
# 20231101 - Added back in the example Verify_Catalog job example that this script
#            for each verify level.
# --------------------------------------------------------------------------------
