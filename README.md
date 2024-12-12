# AutoRestoreAndVerify
When called in a Backup job's Runscript {RunsWhen = after} it will automatically restore the current job, and then trigger all three Verify levels against the job.

This script is meant to be used as an example of how to do these sorts of things with Bacula. It may be used as-is, or parts of it may be pulled out and used in your own custom scripts.

All instructions and examples are included at the top of the script.
