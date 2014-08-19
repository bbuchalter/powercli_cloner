Function Logger([string]$log_data) {
  $logfile = "C:\scripts\vm_backup\log.txt"
  $timestamp = Get-Date
  $date_string = [string]$timestamp
  Add-Content C:\scripts\vm_backup\log.txt "`n$date_string $log_data"
}

# Clear all variables used in this script.
Function ClearVars {
  # Variables should be cleared from the enviornment for many reasons:
  # *Security - we shouldn't leave anything lying around
  # *Debugging - Best to know all variables are reset so that previously failed runs don't interfere

  remove-item -Path "variable:backup_list" -ErrorAction SilentlyContinue
  remove-item -Path "variable:vcenter_server" -ErrorAction SilentlyContinue
  remove-item -Path "variable:backup_search_string" -ErrorAction SilentlyContinue
  remove-item -Path "variable:old_backups" -ErrorAction SilentlyContinue
  remove-item -Path "variable:old_backup_count" -ErrorAction SilentlyContinue
  remove-item -Path "variable:target_host" -ErrorAction SilentlyContinue
  remove-item -Path "variable:target_host_view" -ErrorAction SilentlyContinue
  remove-item -Path "variable:target_ds" -ErrorAction SilentlyContinue
  remove-item -Path "variable:target_ds_view" -ErrorAction SilentlyContinue
  remove-item -Path "variable:source_vm" -ErrorAction SilentlyContinue
  remove-item -Path "variable:source_vm_view" -ErrorAction SilentlyContinue
  remove-item -Path "variable:backup_date" -ErrorAction SilentlyContinue
  remove-item -Path "variable:snapshot_name" -ErrorAction SilentlyContinue
  remove-item -Path "variable:snapshot" -ErrorAction SilentlyContinue
  remove-item -Path "variable:snapshot_view" -ErrorAction SilentlyContinue
  remove-item -Path "variable:cloneFolder" -ErrorAction SilentlyContinue
  remove-item -Path "variable:cloneSpec" -ErrorAction SilentlyContinue
  remove-item -Path "variable:cloneName" -ErrorAction SilentlyContinue
  remove-item -Path "variable:clone" -ErrorAction SilentlyContinue
  remove-item -Path "variable:cloneFolder" -ErrorAction SilentlyContinue
  remove-item -Path "variable:number_of_backups_retained" -ErrorAction SilentlyContinue
  remove-item -Path "variable:current_backup_count" -ErrorAction SilentlyContinue
  remove-item -Path "variable:customer" -ErrorAction SilentlyContinue
  remove-item -Path "variable:number_of_backups_expired" -ErrorAction SilentlyContinue
  remove-item -Path "variable:sorted_old_backups" -ErrorAction SilentlyContinue
  remove-item -Path "variable:expired_backups" -ErrorAction SilentlyContinue
  remove-item -Path "variable:expired_backup_vm" -ErrorAction SilentlyContinue
  remove-item -Path "variable:sorted_old_backups" -ErrorAction SilentlyContinue
}

ClearVars

$backup_list =  Import-Csv C:\scripts\vm_backup\safe_backup_list.csv
$vcenter_server = "vcenter"


# Check if VMware snapin is loaded before loading
if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) {
    Logger("Loading VMware snap in")
    Add-PsSnapin VMware.VimAutomation.Core
}

# Assumes script is being run as a user with vSphere privileges
Logger("Connecting to VIServer $vcenter_server")
Connect-VIServer $vcenter_server

foreach ($customer in $backup_list) {

    Logger("Processing backup for $customer")

    $target_host = Get-VMHost -Name $customer.TargetHost
    $target_host_state = $target_host.state
    Logger("Target Host: $target_host ($target_host_state)")
    if($target_host_state -eq "Connected") {

        # Must get old backups before creating new one 
        # To make sure we never accidently expire (a.k.a. delete) the current backup
        $backup_search_string = $customer.SourceVM + "-*-backup"
        Logger("Searching for old backups matching $backup_search_string")
        
        $old_backups = Get-VM -Datastore $customer.TargetDS -Name $backup_search_string
        # Must duplicate $old_backups to not affect it when casting below
        $old_backup_count = $old_backups
        # Must explicitly cast results into array to return a valid count when only one item is returned
        # Also, cannot cast on $old_backups, destructive
        $old_backup_count = ([array]$old_backup_count).Count
        
        Logger("Found $old_backup_count old backups")
        
        
        $target_host_view = $target_host | Get-View
        $target_ds = Get-Datastore -Name $customer.TargetDS
        $target_ds_view = $target_ds | Get-View
        $source_vm = Get-VM $customer.SourceVM
        $source_vm_view = $source_vm | Get-View
        
        $backup_date = Get-Date -Format "yyyy-MM-dd-HH:mm"

        If ($target_host) {

            $snapshot_name = "$backup_date backup"
            Logger("Starting snapshot")
            $snapshot = New-Snapshot -VM $source_vm -Name $snapshot_name
            Logger("Snapshot done")
            $snapshot_view = $snapshot | Get-View
            
            if($snapshot_view) {
              Logger("Snapshot created successfully")
            
              # Get folder of VM
              $cloneFolder = $source_vm_view.parent
            
              # Build clone specification
              $cloneSpec = new-object Vmware.Vim.VirtualMachineCloneSpec
              $cloneSpec.Snapshot = $snapshot_view.MoRef
              $cloneSpec.Location = new-object Vmware.Vim.VirtualMachineRelocateSpec
              #  Thin provisioning
              $cloneSpec.Location.Transform =  [Vmware.Vim.VirtualMachineRelocateTransformation]::sparse
              $cloneSpec.Location.Datastore = $target_ds_view.MoRef
              $cloneSpec.Location.Host = $target_host_view.MoRef
              # Target Resource Pool, based on first VM in TargetHost
              # TODO: Handle cass where no VMs exist on VMHost
              $cloneSpec.Location.Pool = ($target_host | Get-VM | Select-Object -First 1 | Get-View).ResourcePool
              
              # Full clone, flatten all children snapshots
              # See http://www.vmdev.info/?p=202
              $cloneSpec.Location.DiskMoveType = [Vmware.Vim.VirtualMachineRelocateDiskMoveOptions]::moveAllDiskBackingsAndDisallowSharing
            
              $cloneName = "$source_vm-$backup_date-backup"
            
            
              # Create clone
              # This method returns a Task object with which to monitor the operation
              # The info.result property in the Task contains the newly added VirtualMachine upon success.
              Logger("Staring clone into $cloneName")
              $clone = $source_vm_view.CloneVM( $cloneFolder, $cloneName, $cloneSpec )
              Logger("Clone complete. Removing snapshot.")
            
              # Remove Snapshot created for clone, will queue automatically
              $snapshot | Remove-Snapshot -confirm:$False
              Logger("Snapshot deleted.")
              
              if($clone) {
                #Clone created successfully
                Logger("Clone completed successfully.")
                
                
                $number_of_backups_retained = [int]$customer.BackupsRetained
                $current_backup_count = $old_backup_count + 1 #Add 1 to account for new backup
                
                
                $number_of_backups_expired = $current_backup_count - $number_of_backups_retained
                
                Logger("Number of backups expired: $number_of_backups_expired")
                Logger("Number of backups retained: $number_of_backups_retained")
                
                # Check to make sure we need to delete expired backups AND
                # That we will be keeping at least one backup
                if ( ($number_of_backups_expired -gt 0) -and ($number_of_backups_retained -gt 0) ) {
                
                  if ( $old_backup_count -eq 1) {
                  
                    # When it's just a single old backup, don't loop, sort, etc...
                    # In addition to being more effecient, you can't access an index of
                    # $old_backups when it has only one element!
                    Logger("Deleting old backup: $old_backups")
                    Remove-VM -VM $old_backups -DeleteFromDisk -Confirm:$false
                    
                    
                  } 
                  else {
                    # Multiple old backups
                    
                    
                    # Because the date is in the Name, we can sort in ascending order (default behavior) to get oldest backups first.
                    $sorted_old_backups = $old_backups | Sort-Object Name
        
                    $expired_backups = $sorted_old_backups[0..$number_of_backups_expired]
                    foreach($expired_backup_vm in $expired_backups) {
                      Logger("Deleting old backup $expired_backup_vm")
        		      Remove-VM -VM $expired_backup_vm -DeleteFromDisk -Confirm:$false
                    }  #for each expired backup
                  } # if old_backup_count == 1
                } # if number of expired backups gt 0
              } #if clone
            } #if snapshot
          } #if target host
        #if target_host connected
        } else { 
          Logger("Host $target_host not in connected state.")
        }
        Logger("Backup complete for $customer")
        Logger("================")
        Logger("================")
        Logger("================")
    } #for each customer

#Disconnect from vSphere
Logger("Disconnecting from vSphere")
Disconnect-VIServer -Confirm:$false

ClearVars
