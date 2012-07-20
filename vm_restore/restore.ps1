add-pssnapin VMware.VimAutomation.Core

$vcenter_server = "vcenter"
$restore_to_datastore = "DS1-T610-PERC6i"
$restore_to_host = "192.168.1.244"
$backup_from_host = "192.168.1.240"

Write-Host "Connecting to vSphere Server..."
Connect-VIServer $vcenter_server

Write-Host "Searching for backups..."
$backups = Get-VMHost $backup_from_host | Get-VM *-backup
if($backups) {
	foreach($backup in $backups) {
		Write-Host "Found backup $backup.name"
	}
}


if($backups.count -eq 0) {
	Write-Host "No Backups found.  Press any key to exit."
	$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp,AllowCtrlC")
}
Else {
	Write-Host "To delete their equivilants on the T610 and restore from the 2950 press any key.  To exit press CTRL+c."
	$y = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp,AllowCtrlC")
    
    $length_of_backup_info_appeneded_to_vm_name = 22
    
	foreach($backup in $backups) {
        $restore_name_length = $backup.name.length - $length_of_backup_info_appeneded_to_vm_name
		$restore_name = $backup.name.substring(0, $restore_name_length)
		
		$delete_vm = Get-VM -Name $restore_name -ErrorAction SilentlyContinue
		if($delete_vm -eq $null) {
		
		}
		Else {
        	Write-Host "Deleting on T610 $delete_vm.name VM"
		    Stop-VM $delete_vm.name -Confirm:$false
		    Get-VM $delete_vm | Remove-VM -DeleteFromDisk -Confirm:$false
        }

		Write-Host "Cloning $backup.name back to T610 as $restore_name..."
		
		

        Write-Host "Create new snapshot for clone..."
        $cloneSnap = $backup | New-Snapshot -Name "Clone Snapshot"
        
        # Get managed object view
        $vmView = $backup | Get-View
        
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
        $cloneSpec.Location.Datastore = (Get-Datastore -Name $restore_to_datastore | Get-View).MoRef
        #Target Host
        $cloneSpec.Location.Host = (Get-VMHost -Name $restore_to_host | Get-View).MoRef
        #Target Resource Pool, based on first VM in TargetHost
        $cloneSpec.Location.Pool = (Get-VMHost -Name $restore_to_host | Get-VM | Select-Object -First 1 | Get-View).ResourcePool
        
        #Set Clone name
        $cloneName = $restore_name
        
        
        # Create clone
        $clone_task = $vmView.CloneVM_Task( $cloneFolder, $cloneName, $cloneSpec )
         
        
        # Remove Snapshot created for clone, will queue automatically
        Get-Snapshot -VM (Get-VM -Name $backup) -Name $cloneSnap | Remove-Snapshot -confirm:$False



	}

	

}