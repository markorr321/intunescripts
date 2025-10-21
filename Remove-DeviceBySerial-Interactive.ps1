#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Interactive device removal - Select devices from a grid to delete from Autopilot, Intune, and Entra ID

.DESCRIPTION
    This script shows all devices in an interactive grid where you can select which ones to delete from:
    - Windows Autopilot
    - Microsoft Intune
    - Microsoft Entra ID (Azure AD)

.PARAMETER WhatIf
    Shows what would be deleted without actually performing the deletion

.EXAMPLE
    .\Remove-DeviceBySerial-Interactive.ps1
    
.EXAMPLE
    .\Remove-DeviceBySerial-Interactive.ps1 -WhatIf
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check Graph connection
function Test-GraphConnection {
    try {
        $context = Get-MgContext
        if ($null -eq $context) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

# Function to connect to Microsoft Graph
function Connect-ToGraph {
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    
    $requiredScopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All", 
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        Write-ColorOutput "✓ Successfully connected to Microsoft Graph" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "✗ Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to get all Autopilot devices
function Get-AllAutopilotDevices {
    Write-ColorOutput "Retrieving all Autopilot devices..." "Yellow"
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
        $allDevices = @()
        
        do {
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET
            if ($response.value) {
                $allDevices += $response.value
            }
            $uri = $response.'@odata.nextLink'
        } while ($uri)
        
        Write-ColorOutput "Found $($allDevices.Count) Autopilot devices" "Green"
        return $allDevices
    }
    catch {
        Write-ColorOutput "Error retrieving Autopilot devices: $($_.Exception.Message)" "Red"
        return @()
    }
}


# Function to get matching Entra ID device by device name with serial validation
function Get-EntraDeviceByName {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        return @()
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
        $AADDevices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        
        if (-not $AADDevices -or $AADDevices.Count -eq 0) {
            Write-ColorOutput "Device $DeviceName not found in Entra ID." "Yellow"
            return @()
        }
        
        # Log if we found duplicates
        if ($AADDevices.Count -gt 1) {
            Write-ColorOutput "Found $($AADDevices.Count) devices with name '$DeviceName' in Entra ID. Will process all duplicates." "Yellow"
        }
        
        # If we have a serial number, validate each device
        if ($SerialNumber) {
            $validatedDevices = @()
            foreach ($AADDevice in $AADDevices) {
                $deviceSerial = $null
                if ($AADDevice.physicalIds) {
                    foreach ($physicalId in $AADDevice.physicalIds) {
                        if ($physicalId -match '\[SerialNumber\]:(.+)') {
                            $deviceSerial = $matches[1].Trim()
                            break
                        }
                    }
                }
                
                # If serial numbers match or device has no serial, include it
                if (-not $deviceSerial -or $deviceSerial -eq $SerialNumber) {
                    $validatedDevices += $AADDevice
                    if ($deviceSerial) {
                        Write-ColorOutput "Validated Entra device: $($AADDevice.displayName) (Serial: $deviceSerial)" "Green"
                    }
                } else {
                    Write-ColorOutput "Skipping Entra ID device with ID $($AADDevice.id) - serial number mismatch (Device: $deviceSerial, Expected: $SerialNumber)" "Yellow"
                }
            }
            return $validatedDevices
        }
        
        return $AADDevices
    }
    catch {
        Write-ColorOutput "Error searching for Entra devices: $($_.Exception.Message)" "Red"
        return @()
    }
}

# Function to get paged results from Graph API
function Get-GraphPagedResults {
    param([string]$Uri)
    
    $allResults = @()
    $currentUri = $Uri
    
    do {
        try {
            $response = Invoke-MgGraphRequest -Uri $currentUri -Method GET
            if ($response.value) {
                $allResults += $response.value
            }
            $currentUri = $response.'@odata.nextLink'
        }
        catch {
            Write-ColorOutput "Error getting paged results: $($_.Exception.Message)" "Red"
            break
        }
    } while ($currentUri)
    
    return $allResults
}

# Function to get Autopilot device with advanced search
function Get-AutopilotDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $AutopilotDevice = $null
    
    # Try to find by serial number first if available
    if ($SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')"
            $AutopilotDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($AutopilotDevice) {
                Write-ColorOutput "Found Autopilot device by serial number: $($AutopilotDevice.displayName)" "Green"
                return $AutopilotDevice
            } else {
                Write-ColorOutput "Device with serial $SerialNumber not found in Autopilot, trying by display name..." "Yellow"
            }
        }
        catch {
            Write-ColorOutput "Error searching Autopilot by serial number: $($_.Exception.Message)" "Yellow"
        }
    }
    
    # If not found by serial number or no serial number available, try by display name
    if (-not $AutopilotDevice -and $DeviceName) {
        Write-ColorOutput "Searching Autopilot by display name: $DeviceName (using client-side filtering)" "Yellow"
        try {
            # Get all Autopilot devices and filter client-side since API doesn't support displayName filtering
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
            $allAutopilotDevices = Get-GraphPagedResults -Uri $uri
            
            # Filter by display name (case-insensitive partial match)
            $AutopilotDevice = $allAutopilotDevices | Where-Object { 
                $_.displayName -and $_.displayName -like "*$DeviceName*" 
            } | Select-Object -First 1
            
            if ($AutopilotDevice) {
                Write-ColorOutput "Found Autopilot device matching display name: $($AutopilotDevice.displayName)" "Green"
            }
        }
        catch {
            Write-ColorOutput "Error searching Autopilot devices by display name: $($_.Exception.Message)" "Red"
        }
    }
    
    return $AutopilotDevice
}

# Function to remove device from Autopilot
function Remove-AutopilotDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $AutopilotDevice = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    
    if (-not $AutopilotDevice) {
        $searchCriteria = if ($SerialNumber) { "serial $SerialNumber or name $DeviceName" } else { "name $DeviceName" }
        Write-ColorOutput "Device with $searchCriteria not found in Autopilot." "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($AutopilotDevice.id)"
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Autopilot device: $($AutopilotDevice.displayName) (Serial: $($AutopilotDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "✓ Successfully removed device $DeviceName from Autopilot (ID: $($AutopilotDevice.id))." "Green"
            return @{ Success = $true; Found = $true; Error = $null }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-ColorOutput "✗ Error removing device $DeviceName from Autopilot: $errorMsg" "Red"
        return @{ Success = $false; Found = $true; Error = $errorMsg }
    }
}

# Function to get Intune device with enhanced search
function Get-IntuneDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $IntuneDevice = $null
    
    # Try by device name first if available
    if ($DeviceName) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$DeviceName'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($IntuneDevice) {
                Write-ColorOutput "Found Intune device by name: $($IntuneDevice.deviceName)" "Green"
                return $IntuneDevice
            }
        }
        catch {
            Write-ColorOutput "Error searching Intune by device name: $($_.Exception.Message)" "Yellow"
        }
    }
    
    # If not found by name and we have serial number, try by serial
    if (-not $IntuneDevice -and $SerialNumber) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'"
            $IntuneDevice = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($IntuneDevice) {
                Write-ColorOutput "Found Intune device by serial number: $($IntuneDevice.deviceName)" "Green"
            }
        }
        catch {
            Write-ColorOutput "Error searching Intune by serial number: $($_.Exception.Message)" "Yellow"
        }
    }
    
    return $IntuneDevice
}

# Function to remove device from Intune
function Remove-IntuneDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    $IntuneDevice = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    
    if (-not $IntuneDevice) {
        Write-ColorOutput "Device $DeviceName not found in Intune." "Yellow"
        return @{ Success = $false; Found = $false; Error = "Device not found" }
    }
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($IntuneDevice.id)"
        
        if ($WhatIf) {
            Write-ColorOutput "WHATIF: Would remove Intune device: $($IntuneDevice.deviceName) (Serial: $($IntuneDevice.serialNumber))" "Yellow"
            return @{ Success = $true; Found = $true; Error = $null }
        } else {
            Invoke-MgGraphRequest -Uri $uri -Method DELETE
            Write-ColorOutput "✓ Successfully removed device $DeviceName from Intune." "Green"
            return @{ Success = $true; Found = $true; Error = $null }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-ColorOutput "✗ Error removing device $DeviceName from Intune: $errorMsg" "Red"
        return @{ Success = $false; Found = $true; Error = $errorMsg }
    }
}

# Function to remove multiple Entra ID devices with enhanced error handling
function Remove-EntraDevices {
    param(
        [array]$Devices,
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    if (-not $Devices -or $Devices.Count -eq 0) {
        return @{ Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
    }
    
    $deletedCount = 0
    $failedCount = 0
    $allErrors = @()
    
    foreach ($AADDevice in $Devices) {
        # Extract serial number from physicalIds for logging
        $deviceSerial = $null
        if ($AADDevice.physicalIds) {
            foreach ($physicalId in $AADDevice.physicalIds) {
                if ($physicalId -match '\[SerialNumber\]:(.+)') {
                    $deviceSerial = $matches[1].Trim()
                    break
                }
            }
        }
        
        try {
            $uri = "https://graph.microsoft.com/v1.0/devices/$($AADDevice.id)"
            
            if ($WhatIf) {
                Write-ColorOutput "WHATIF: Would remove Entra ID device: $($AADDevice.displayName) (ID: $($AADDevice.id), Serial: $deviceSerial)" "Yellow"
                $deletedCount++
            } else {
                Invoke-MgGraphRequest -Uri $uri -Method DELETE
                $deletedCount++
                Write-ColorOutput "✓ Successfully removed device $DeviceName (ID: $($AADDevice.id), Serial: $deviceSerial) from Entra ID." "Green"
            }
        }
        catch {
            $failedCount++
            $errorMsg = $_.Exception.Message
            $allErrors += $errorMsg
            Write-ColorOutput "✗ Error removing device $DeviceName (ID: $($AADDevice.id)) from Entra ID: $errorMsg" "Red"
        }
    }
    
    # Determine overall success
    $success = $false
    if ($deletedCount -gt 0 -and $failedCount -eq 0) {
        $success = $true
        if ($deletedCount -gt 1) {
            Write-ColorOutput "Successfully removed all $deletedCount duplicate devices named '$DeviceName' from Entra ID." "Green"
        }
    }
    elseif ($deletedCount -gt 0 -and $failedCount -gt 0) {
        Write-ColorOutput "Partial success: Deleted $deletedCount device(s), failed to delete $failedCount device(s) from Entra ID." "Yellow"
    }
    
    return @{
        Success = $success
        DeletedCount = $deletedCount
        FailedCount = $failedCount
        Errors = $allErrors
    }
}

# Main execution
Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "    Interactive Device Removal Tool" "Magenta"
Write-ColorOutput "=================================================" "Magenta"

if ($WhatIf) {
    Write-ColorOutput "Mode: WHATIF (No actual deletions will be performed)" "Yellow"
}
Write-ColorOutput ""

# Check if already connected to Graph
if (-not (Test-GraphConnection)) {
    if (-not (Connect-ToGraph)) {
        Write-ColorOutput "Failed to connect to Microsoft Graph. Exiting." "Red"
        exit 1
    }
}

# Get all Autopilot devices
$autopilotDevices = Get-AllAutopilotDevices

if ($autopilotDevices.Count -eq 0) {
    Write-ColorOutput "No Autopilot devices found. Exiting." "Yellow"
    exit 0
}

# Create enhanced device objects with additional info
Write-ColorOutput "Enriching device information..." "Yellow"
$enrichedDevices = foreach ($device in $autopilotDevices) {
    $intuneDevice = Get-IntuneDevice -DeviceName $device.displayName -SerialNumber $device.serialNumber
    $entraDevices = Get-EntraDeviceByName -DeviceName $device.displayName -SerialNumber $device.serialNumber
    $entraDevice = if ($entraDevices -and $entraDevices.Count -gt 0) { $entraDevices[0] } else { $null }
    
    [PSCustomObject]@{
        AutopilotId = $device.id
        DisplayName = if ($device.displayName) { $device.displayName } else { "N/A" }
        SerialNumber = $device.serialNumber
        Model = $device.model
        Manufacturer = $device.manufacturer
        GroupTag = if ($device.groupTag) { $device.groupTag } else { "None" }
        DeploymentProfile = if ($device.deploymentProfileAssignmentStatus) { $device.deploymentProfileAssignmentStatus } else { "None" }
        IntuneFound = if ($intuneDevice) { "Yes" } else { "No" }
        IntuneId = if ($intuneDevice) { $intuneDevice.id } else { $null }
        IntuneName = if ($intuneDevice) { $intuneDevice.deviceName } else { "N/A" }
        EntraFound = if ($entraDevice) { "Yes" } else { "No" }
        EntraId = if ($entraDevice) { $entraDevice.id } else { $null }
        EntraName = if ($entraDevice) { $entraDevice.displayName } else { "N/A" }
        # Store original objects for deletion
        _AutopilotDevice = $device
        _IntuneDevice = $intuneDevice
        _EntraDevice = $entraDevice
    }
}

Write-ColorOutput "Device information enriched. Opening selection grid..." "Green"
Write-ColorOutput ""
Write-ColorOutput "Instructions:" "Cyan"
Write-ColorOutput "1. Select one or more devices in the grid by clicking on them" "White"
Write-ColorOutput "2. Press ENTER or click OK to proceed with deletion" "White"
Write-ColorOutput "3. Press ESC or click Cancel to exit without changes" "White"
Write-ColorOutput ""

# Show interactive grid for device selection
$selectedDevices = $enrichedDevices | Select-Object DisplayName, SerialNumber, Model, Manufacturer, GroupTag, DeploymentProfile, IntuneFound, EntraFound, IntuneName, EntraName | Out-GridView -Title "Select Devices to Remove from All Services" -PassThru

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-ColorOutput "No devices selected. Exiting." "Yellow"
    exit 0
}

Write-ColorOutput "=================================================" "Magenta"
Write-ColorOutput "Processing $($selectedDevices.Count) selected device(s)" "White"
Write-ColorOutput "=================================================" "Magenta"

# Process each selected device with enhanced logic
$results = @()
foreach ($selectedDevice in $selectedDevices) {
    # Find the full device info
    $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
    $deviceName = $fullDevice.DisplayName
    $serialNumber = $fullDevice.SerialNumber
    
    Write-ColorOutput "`n--- Processing: $deviceName (Serial: $serialNumber) ---" "Cyan"
    
    $deviceResult = [PSCustomObject]@{
        SerialNumber = $serialNumber
        DisplayName = $deviceName
        EntraID = @{ Found = $false; Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
        Intune = @{ Found = $false; Success = $false; Error = $null }
        Autopilot = @{ Found = $false; Success = $false; Error = $null }
    }
    
    # Remove from Entra ID with enhanced logic
    Write-ColorOutput "Processing Entra ID removal..." "Yellow"
    $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $serialNumber
    if ($entraDevices -and $entraDevices.Count -gt 0) {
        $deviceResult.EntraID.Found = $true
        $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $deviceName -SerialNumber $serialNumber
        $deviceResult.EntraID.Success = $entraResult.Success
        $deviceResult.EntraID.DeletedCount = $entraResult.DeletedCount
        $deviceResult.EntraID.FailedCount = $entraResult.FailedCount
        $deviceResult.EntraID.Errors = $entraResult.Errors
    } else {
        Write-ColorOutput "Not found in Entra ID" "Gray"
    }
    
    # Remove from Intune with enhanced logic
    Write-ColorOutput "Processing Intune removal..." "Yellow"
    $intuneResult = Remove-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Intune.Found = $intuneResult.Found
    $deviceResult.Intune.Success = $intuneResult.Success
    $deviceResult.Intune.Error = $intuneResult.Error
    
    # Remove from Autopilot with enhanced logic
    Write-ColorOutput "Processing Autopilot removal..." "Yellow"
    $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Autopilot.Found = $autopilotResult.Found
    $deviceResult.Autopilot.Success = $autopilotResult.Success
    $deviceResult.Autopilot.Error = $autopilotResult.Error
    
    $results += $deviceResult
}

# Summary
Write-ColorOutput "`n=================================================" "Magenta"
Write-ColorOutput "                   SUMMARY" "Magenta"
Write-ColorOutput "=================================================" "Magenta"

if ($WhatIf) {
    Write-ColorOutput "WHATIF Results:" "Yellow"
} else {
    Write-ColorOutput "Deletion Results:" "White"
}

foreach ($result in $results) {
    Write-ColorOutput "`nDevice: $($result.DisplayName) (Serial: $($result.SerialNumber))" "White"
    
    # Entra ID Status
    if ($result.EntraID.Found) {
        if ($result.EntraID.Success) {
            $entraStatus = "✓ Success"
            if ($result.EntraID.DeletedCount -gt 1) {
                $entraStatus += " ($($result.EntraID.DeletedCount) devices)"
            }
            $entraColor = "Green"
        } else {
            $entraStatus = "✗ Failed"
            if ($result.EntraID.DeletedCount -gt 0) {
                $entraStatus += " (Partial: $($result.EntraID.DeletedCount)/$($result.EntraID.DeletedCount + $result.EntraID.FailedCount))"
            }
            $entraColor = "Red"
        }
    } else {
        $entraStatus = "Not Found"
        $entraColor = "Gray"
    }
    
    # Intune Status
    if ($result.Intune.Found) {
        $intuneStatus = if ($result.Intune.Success) { "✓ Success" } else { "✗ Failed" }
        $intuneColor = if ($result.Intune.Success) { "Green" } else { "Red" }
    } else {
        $intuneStatus = "Not Found"
        $intuneColor = "Gray"
    }
    
    # Autopilot Status
    if ($result.Autopilot.Found) {
        $autopilotStatus = if ($result.Autopilot.Success) { "✓ Success" } else { "✗ Failed" }
        $autopilotColor = if ($result.Autopilot.Success) { "Green" } else { "Red" }
    } else {
        $autopilotStatus = "Not Found"
        $autopilotColor = "Gray"
    }
    
    Write-ColorOutput "  Entra ID:  $entraStatus" $entraColor
    Write-ColorOutput "  Intune:    $intuneStatus" $intuneColor
    Write-ColorOutput "  Autopilot: $autopilotStatus" $autopilotColor
    
    # Show errors if any
    if ($result.EntraID.Errors -and $result.EntraID.Errors.Count -gt 0) {
        Write-ColorOutput "    Entra Errors: $($result.EntraID.Errors -join '; ')" "Red"
    }
    if ($result.Intune.Error) {
        Write-ColorOutput "    Intune Error: $($result.Intune.Error)" "Red"
    }
    if ($result.Autopilot.Error) {
        Write-ColorOutput "    Autopilot Error: $($result.Autopilot.Error)" "Red"
    }
}

$totalProcessed = $results.Count
$totalEntraSuccess = ($results | Where-Object { $_.EntraID.Found -and $_.EntraID.Success }).Count
$totalIntuneSuccess = ($results | Where-Object { $_.Intune.Found -and $_.Intune.Success }).Count
$totalAutopilotSuccess = ($results | Where-Object { $_.Autopilot.Found -and $_.Autopilot.Success }).Count

$totalEntraFound = ($results | Where-Object { $_.EntraID.Found }).Count
$totalIntuneFound = ($results | Where-Object { $_.Intune.Found }).Count
$totalAutopilotFound = ($results | Where-Object { $_.Autopilot.Found }).Count

Write-ColorOutput "`nOverall Results:" "White"
Write-ColorOutput "  Devices Processed: $totalProcessed" "White"
Write-ColorOutput "  Entra ID: $totalEntraSuccess/$totalEntraFound found" $(if ($totalEntraFound -eq 0) { "Gray" } elseif ($totalEntraSuccess -eq $totalEntraFound) { "Green" } else { "Yellow" })
Write-ColorOutput "  Intune: $totalIntuneSuccess/$totalIntuneFound found" $(if ($totalIntuneFound -eq 0) { "Gray" } elseif ($totalIntuneSuccess -eq $totalIntuneFound) { "Green" } else { "Yellow" })
Write-ColorOutput "  Autopilot: $totalAutopilotSuccess/$totalAutopilotFound found" $(if ($totalAutopilotFound -eq 0) { "Gray" } elseif ($totalAutopilotSuccess -eq $totalAutopilotFound) { "Green" } else { "Yellow" })

Write-ColorOutput "`nOperation completed!" "Green"
Write-ColorOutput "=================================================" "Magenta"
