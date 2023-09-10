# Jamf Client Communications Doctor

Jamf Pro doesn’t have guard rails in place for when it runs policies or inventory updates to ensure communications remain stable. Of primary concern is the jamf process doesn’t place time limits on how long a policy or extension attribute is allowed to run. In addition to this all tasks are run sequentially. If a single process hangs this will cause all other pending tasks to wait indefinitely for it to complete, which may never happen. In the Jamf Pro Server console this may reflect computers not properly having inventory updated or will only run some policies on an infrequent basis.  Additionally, Jamf may still list the computer as “checking in,” however there may usually be little to no policy logs.

Some common examples of objects that will cause a hang:
* A script that waits for user input.
* A script that implements JamfHelper or osascript without the timeout flag.
* A script that runs a child process which subsequently hangs.
* The computer goes to sleep during the check-in process.

The Jamf Client Communications Doctor aims to fix this by doing the following:

* Sets a TTL on Policy child processes (default of 14.1 hours per child)
* Sets a TTL on Extension Attribute processes (default of 60 minutes per EA)
* Sets a TTL on Jamf check-ins to 2 days
* Prevents  the computer from system sleeping for the duration of the check-in process
** Display sleep and screen lock are allowed!


Documentation available at https://docs.google.com/document/d/1p0OT3AFrYdS-H6Nio1caa81C-Vug5ZKcRLgKTzUv6zU
