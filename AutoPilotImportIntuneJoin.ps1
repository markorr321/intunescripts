###Set ExecutionPolicy ByPass - Click "Yes to ALL"###
Set-ExecutionPolicy -ExecutionPolicy ByPass

########## VARIABLES ###############
if ((Get-WmiObject -Class:Win32_ComputerSystem).Model -ne "HP ProDesk 400 G3 SFF")
{
    $tag = "field"
}
else 
{
    $tag = "G3 field"
}
 
$hwid = ((Get-WmiObject -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData)
 
$ser = (Get-WmiObject win32_bios).SerialNumber
if([string]::IsNullOrWhiteSpace($ser)) { $ser = $env:COMPUTERNAME}
 
$drives = Get-WmiObject -Class Win32_logicaldisk
 
foreach ($drive in $drives)
{
    if($drive.VolumeName -eq "DVD_ROM")
    {
        $USB_drive = $drive
    }
}
 
$filePath = $USB_drive.deviceID + "\Deploy\Scripts"
$filePath = $filePath + "\serial_number.csv"
 
$SerialNumbers = Import-Csv $filePath
 
$SerialNumberFound = 0
 
foreach ($SerialNumber in $SerialNumbers) 
{
    if ($ser -eq $SerialNumber.SerialNumbers) 
    {
        $wshell = New-Object -ComObject Wscript.Shell
        $wshell.Popup("Valid Serial Number. This dialog Box will close in 15 seconds",15,"Done",0x1)
        $SerialNumberFound = 1
    }
}
 
if ($SerialNumberFound -eq 0) 
{
    $wshell = New-Object -ComObject Wscript.Shell
    $wshell.Popup("Invalid Serial Number. Please Call the help Desk at 913-234-5400",0,"Done",0x1)
    break 
}
 
$ProgressPreference = 'silentlyContinue'
 
################# Get PowerShell modules ###################
 
Install-PackageProvider -Name NuGet -Confirm:$false -Force
Install-Module -Name Microsoft.Graph.Intune -Confirm:$false -Force
Install-Module -Name WindowsAutoPilotIntune -Confirm:$false -Force
 
Import-Module Microsoft.Graph.Intune
Import-Module WindowsAutoPilotIntune
Import-Module AzureAD -Scope Global
 
################## Connect Graph ################
 
$tenant = "qcholdings.onmicrosoft.com"
$authority = "https://login.windows.net/$tenant"
$clientId = "387d8dcd-4639-4b88-ae7e-0808d000a93f"
$clientSecret = "1XQgJznw8Fdh013s1_~BHQ~_V1h-e_PNvJ"
 
Update-MSGraphEnvironment -AppId $clientId -Quiet
Update-MSGraphEnvironment -AuthUrl $authority -Quiet
Connect-MSGraph -ClientSecret $ClientSecret -Quiet
 
Add-AutoPilotImportedDevice -serialNumber $ser -hardwareIdentifier $hwid -groupTag $tag
 
# Data gathering
do {
    $autopilotDevices = Get-AutopilotDevice | Get-MSGraphAllPages
    
    foreach ($device in $autopilotDevices) 
    {
        if ($autopilotDevices.serialNumber -eq $ser) 
        {
            $currentDevice = $device
        }
    }
        
    } while ([string]::IsNullOrEmpty($currentDevice))
 
$wshell = New-Object -ComObject Wscript.Shell
$wshell.Popup("Checking Autopilot Status. This dialog box will close in 15 seconds",15,"Done",0x1)
 
$counter = 0
 
do {
    Start-sleep -s 30
    $wshell = New-Object -ComObject Wscript.Shell
    $wshell.Popup("Checking Autopilot Status. This dialog box will close in 15 seconds",15,"Done",0x1)
} until (($currentDevice.deploymentProfileAssignmentStatus -ne "notAssigned") -and ($currentDevice.deploymentProfileAssignmentStatus -ne "pending") -and $counter -le 31)
 
if ($currentDevice.deploymentProfileAssignmentStatus -eq "failed" -or $counter -eq 31) 
{
    $wshell = New-Object -ComObject Wscript.Shell
    $wshell.Popup("Registration has failed. Please Call the help Desk at 913-234-5400",0,"Done",0x1)
    break 
}
 
$wshell = New-Object -ComObject Wscript.Shell
$wshell.Popup("Autopilot Status Assinged. This dialog box will close in 15 seconds",15,"Done",0x1)
 
write-host "Added into Autopilot" -ForegroundColor green
 
$sysprep = 'C:\Windows\System32\Sysprep\Sysprep.exe'
$arg = '/oobe /reboot /quiet'
$sysprep += " $arg"
Invoke-Expression $sysprep