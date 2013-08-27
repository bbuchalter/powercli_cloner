Automated cloning with VMWare's PowerCLI
========================================

Although End Point is primarily an open source shop, my introduction virtualization was with VMWare.

For automation and scripting, PowerCLI, the PowerShell based command line interface for vSphere, is the platform on which we will build. The process is as follows:
- A scheduled task executes the backup script.
- Delete all old backups to free space.
- Read CSV of VMs to be backed up and the target host and datastore.
- For each VM, snapshot and clone to destination.
- Collect data on cloning failures and email report.

by [Brian Buchalter][Brian Buchalter].
[Brian Buchalter]: http://blog.endpoint.com/2012/07/automated-vm-cloning-with-powercli.html
