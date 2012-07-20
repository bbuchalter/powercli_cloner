add-pssnapin VMware.VimAutomation.Core

# Import Backup CSV
$backupinfo =  Import-Csv C:\scripts\vm_backup\backup_list.csv

#Set VCenter servername
$vcenter_server = "vcenter"

#Connect to vCenter
Connect-VIServer $vcenter_server



# BEGIN OLD BACKUP CLEANUP

#Select all old backups
$old_backups = Get-VM *-backup
if($old_backups) {
	foreach($backup_vm in $old_backups) {
    		Get-VM $backup_vm | Remove-VM -DeleteFromDisk -Confirm:$false
	}
}



# BEGIN QUEUING NEW CLONES

#Increment through CSV
foreach ($customer in $backupinfo) {

    $target_host = Get-VMHost -Name $customer.TargetHost

    If ($target_host) {


        #Set Date format for clone names
        $date = Get-Date -Format "yyyy-MM-dd"

        #Set Date format for emails
        $time = (Get-Date -f "HH:MM")

        #Get SourceVM
        $vm = Get-VM $customer.SourceVM

               
        # Create new snapshot for clone
        $cloneSnap = $vm | New-Snapshot -Name "Clone Snapshot"
        
        # Get managed object view
        $vmView = $vm | Get-View
        
        # Get folder managed object reference
        $cloneFolder = $vmView.parent
        
        # Build clone specification
        $cloneSpec = new-object Vmware.Vim.VirtualMachineCloneSpec
        
        # Make linked disk specification?
        $cloneSpec.Snapshot = $vmView.Snapshot.CurrentSnapshot
        
        #Set VirtualMachineRelocateSpec
        $cloneSpec.Location = new-object Vmware.Vim.VirtualMachineRelocateSpec
        #Thin provisioning
        $cloneSpec.Location.Transform =  [Vmware.Vim.VirtualMachineRelocateTransformation]::sparse
        #Target Datastore
        $cloneSpec.Location.Datastore = (Get-Datastore -Name $customer.TargetDS | Get-View).MoRef
        #Target Host
        $cloneSpec.Location.Host = (Get-VMHost -Name $customer.TargetHost | Get-View).MoRef
        #Target Resource Pool, based on first VM in TargetHost
        $cloneSpec.Location.Pool = (Get-VMHost -Name $customer.TargetHost | Get-VM | Select-Object -First 1 | Get-View).ResourcePool
        
        #Set Clone name
        $cloneName = "$vm-$date-$time-backup"
        
        
        # Create clone
        $clone_task = $vmView.CloneVM_Task( $cloneFolder, $cloneName, $cloneSpec )
        
        # Remove Snapshot created for clone, will queue automatically
        Get-Snapshot -VM (Get-VM -Name $customer.SourceVM) -Name $cloneSnap | Remove-Snapshot -confirm:$False
        
    } 
}

#Disconnect from vCentre
Disconnect-VIServer -Confirm:$false