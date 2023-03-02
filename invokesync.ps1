$IntuneModule = Get-Module -Name "Microsoft.Graph.Intune" -ListAvailable
if (!$IntuneModule){
 
write-host "Microsoft.Graph.Intune Powershell module not installed..." -f Red
write-host "Install by running 'Install-Module Microsoft.Graph.Intune' from an elevated PowerShell prompt" -f Yellow
write-host "Script can't continue..." -f Red
write-host
exit
}
####################################################
# Importing the SDK Module
Import-Module -Name Microsoft.Graph.Intune
 
if(!(Connect-MSGraph)){
Connect-MSGraph
}
####################################################
 
#### Gets all devices running Windows
$Devices = Get-IntuneManagedDevice -Filter "contains(operatingsystem,'Windows')" | Get-MSGraphAllPages
 
Foreach ($Device in $Devices)
{
 
Invoke-IntuneManagedDeviceSyncDevice -managedDeviceId $Device.managedDeviceId
Write-Host "Sending Sync request to Device with DeviceID $($Device.managedDeviceId)" -ForegroundColor Yellow
 
}
 
####################################################

This script performs the following tasks:

Checks if the "Microsoft.Graph.Intune" PowerShell module is installed. If it's not installed, it displays an error message and exits the script.

Imports the "Microsoft.Graph.Intune" module.

Tries to connect to the Microsoft Graph API using the Connect-MSGraph cmdlet. If the connection fails, it prompts the user to authenticate and authorize the script to access the Microsoft Graph API.

Gets all devices running Windows using the Get-IntuneManagedDevice cmdlet with a filter to only return devices that have "Windows" in their operating system name.

Loops through each device returned by Get-IntuneManagedDevice and invokes the Invoke-IntuneManagedDeviceSyncDevice cmdlet with the device's managedDeviceId as a parameter to initiate a synchronization request to the device.

Displays a message for each device that the sync request was sent to.

In summary, the script is used to initiate a synchronization request to all Windows devices that are managed by Intune, using the Microsoft Graph API.

Does this have an impact on the scheduled sync routine of the devices?

No, running this script to initiate a synchronization request on devices does not impact the scheduled sync routine of the devices.

By default, Intune syncs devices on a regular basis to keep the Intune management service up-to-date with the latest information about the managed devices. This script does not change the device sync frequency, but rather it initiates a one-time synchronization request for each device specified in the script.

In other words, this script triggers an immediate synchronization request for the specified devices but does not change the frequency or schedule of the device sync routine. The devices will continue to sync with Intune according to their regular schedule.

Supporting Documentation:

Microsoft Endpoint Manager documentation on Device sync and Intune Management Extension (IME): https://docs.microsoft.com/en-us/mem/intune/protect/device-sync-overview

This article explains how Intune manages device sync, including the different types of sync, how to monitor sync status, and how to troubleshoot sync issues.
Microsoft Graph API documentation on device management: https://docs.microsoft.com/en-us/graph/api/resources/intune-devices-overview?view=graph-rest-beta

This article provides an overview of the Intune device management APIs available through Microsoft Graph, including device synchronization.
Microsoft Endpoint Manager documentation on device management policies: https://docs.microsoft.com/en-us/mem/intune/protect/device-management-policies-overview

This article explains how Intune uses policies to manage devices and how policy updates are distributed to devices.
Based on these articles, it is clear that the script we discussed earlier initiates a one-time synchronization request for specific devices without affecting the regular device sync schedule or frequency. The devices will continue to receive policy updates and sync with Intune according to their regular schedule.