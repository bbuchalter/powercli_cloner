Function Logger([string]$log_data) {
  $timestamp = Get-Date
  $date_string = [string]$timestamp
  Add-Content C:\Users\Administrator\Dropbox\vm_backup\log.txt "`n$date_string $log_data"
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

$backup_list =  Import-Csv C:\Users\Administrator\Dropbox\vm_backup\safe_backup_list.csv
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
        } #if target_host connected
        Logger("Backup complete for $customer")
        Logger("================")
        Logger("================")
        Logger("================")
    } #for each customer



ClearVars

#========================
# EMAIL REPORT
#========================

Function WriteVMStatusToFile
{
    param ([string]$myhost, [string]$file_path)
    
    $VMs = Get-VMHost $myhost | Get-VM
    
    if($VMs){
        foreach($vm in $VMs) {
            Out-File -FilePath $file_path -InputObject $vm.name -Append
            Out-File -FilePath $file_path -InputObject $vm.powerstate -Append
            Out-File -FilePath $file_path -InputObject "--------------------" -Append
            Out-File -FilePath $file_path -InputObject "" -Append
        }
    } 
    else {
        Out-File -FilePath $file_path -InputObject "Server not available." -Append
    }
    
}



#Report path
$report_path = "C:\Users\Administrator\Dropbox\vm_backup\report.txt"

$LastDays = 1

Logger("Writting report for last $LastDays days into $report_path")

    $EventFilterSpecByTime = New-Object VMware.Vim.EventFilterSpecByTime
    If ($LastDays)
    {
        $EventFilterSpecByTime.BeginTime = (get-date).AddDays(-$($LastDays))
    }
    $EventFilterSpec = New-Object VMware.Vim.EventFilterSpec
    $EventFilterSpec.Time = $EventFilterSpecByTime
    $EventFilterSpec.DisableFullMessage = $False
    $EventFilterSpec.Type = "VmCloneFailedEvent"
    $EventManager = Get-View EventManager
    $NewCloneTasks = $EventManager.QueryEvents($EventFilterSpec)

    Out-File -FilePath $report_path -InputObject "CLONE FAILURES:"
    Out-File -FilePath $report_path -InputObject "==================" -Append
 
 if($NewCloneTasks) {
    Foreach ($Task in $NewCloneTasks)
    {
        
        $item = "Destination host: " + $Task.destHost.name
        Out-File -FilePath $report_path -InputObject $item -Append
        $item = "VM Name: " + $Task.destName
        Out-File -FilePath $report_path -InputObject $item -Append
        $item = "Errors: " + $Task.reason.localizedMessage
        Out-File -FilePath $report_path -InputObject $item -Append
        Out-File -FilePath $report_path -InputObject "" -Append
    }
 } else {
   Out-File -FilePath $report_path -InputObject "There were no clone failures in the last 24 hours." -Append
 }
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "VMs on 2950:" -Append
    Out-File -FilePath $report_path -InputObject "=====================" -Append
    WriteVMStatusToFile "192.168.1.240" $report_path
   
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "VMs on T610:" -Append
    Out-File -FilePath $report_path -InputObject "=====================" -Append
    WriteVMStatusToFile "192.168.1.244" $report_path
    
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "" -Append
    Out-File -FilePath $report_path -InputObject "VMs on Offsite:" -Append
    Out-File -FilePath $report_path -InputObject "=====================" -Append
    WriteVMStatusToFile "192.168.1.239" $report_path
    
    
    
#* =========================
#* SMTP Mail Alert
#* =========================

#* Create new .NET object and assign to variable
$mail = New-Object System.Net.Mail.MailMessage

#* Sender Address
$mail.From = "vsphere@coogle.alexcooper.com";

#* Recipient Address
$mail.To.Add("alexcooper@endpoint.com");
$mail.To.Add("matt@alexcooper.com");

#* Message Subject
$mail.Subject = "Alex Cooper VM Backup Report";

#* Message Body
$mail.Body = (Get-Content $report_path | out-string)

#* Connect to your mail server
$smtp = New-Object System.Net.Mail.SmtpClient("192.168.1.252");

#* Send Email
Logger("Emailing report")
$smtp.Send($mail);
Logger("Email sent")


#======================
# SHUTDOWN
#======================

$offsite = Get-VMHost 192.168.1.239

if($offsite) {
    Logger("Begin monitoring of offsite file server sync completition for offsite host shutdown")
    $offsite_fileserver = Get-VM -Name "fsoffsite" 
    while($offsite_fileserver.powerstate -eq "PoweredOn") {
        Logger("Waiting for offsite fileserver to shut down.")
        Start-Sleep -s 60
        $offsite_fileserver = Get-VM -Name "fsoffsite" 
    }
    $offsite_fileserver_powerstate = $offsite_fileserver.powerstate
    Logger("Offsite file server now $offsite_fileserver_powerstate")
    Logger("Shutting down offsite host")
    $offsite | %{Get-View $_.ID} | %{$_.ShutdownHost_Task($TRUE)}
}

#Disconnect from vSphere
Logger("Disconnecting from vSphere")
Disconnect-VIServer -Confirm:$false

#Because the local vSphere server can sometimes 
#stop reading the state of hosts properly
#a restart after each backup inreases chances of
# a successful backup
Logger("Restarting vCenter server")
Restart-Computer
Logger("")
Logger("")
Logger("")
Logger("")
Logger("")