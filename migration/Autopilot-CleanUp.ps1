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

.DESCRIPTION
    After removing devices, the script automatically monitors every 5 seconds to check when
    devices are completely removed from Autopilot and Intune, providing real-time status updates.

.EXAMPLE
    .\Autopilot-CleanUp.ps1
    
.EXAMPLE
    .\Autopilot-CleanUp.ps1 -WhatIf
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
                # Only show message during initial search, not during monitoring
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Found Autopilot device by serial number: $($AutopilotDevice.displayName)" "Green"
                }
                return $AutopilotDevice
            } else {
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Device with serial $SerialNumber not found in Autopilot, trying by display name..." "Yellow"
                }
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
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Found Intune device by name: $($IntuneDevice.deviceName)" "Green"
                }
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
                if (-not $script:MonitoringMode) {
                    Write-ColorOutput "Found Intune device by serial number: $($IntuneDevice.deviceName)" "Green"
                }
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

# Function to verify device removal from Intune
function Test-IntuneDeviceRemoved {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 10
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 30 # seconds
    
    Write-ColorOutput "Verifying device removal from Intune (max wait: $MaxWaitMinutes minutes)..." "Yellow"
    
    do {
        Start-Sleep -Seconds $checkInterval
        $device = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
        
        if (-not $device) {
            $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-ColorOutput "✓ Device confirmed removed from Intune after $elapsedTime minutes" "Green"
            return $true
        }
        
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-ColorOutput "Device still present in Intune after $elapsedTime minutes..." "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "⚠ Device still present in Intune after $MaxWaitMinutes minutes" "Red"
    return $false
}

# Function to verify device removal from Entra ID
function Test-EntraDeviceRemoved {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 10
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 30 # seconds
    
    Write-ColorOutput "Verifying device removal from Entra ID (max wait: $MaxWaitMinutes minutes)..." "Yellow"
    
    do {
        Start-Sleep -Seconds $checkInterval
        $devices = Get-EntraDeviceByName -DeviceName $DeviceName -SerialNumber $SerialNumber
        
        if (-not $devices -or $devices.Count -eq 0) {
            $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-ColorOutput "✓ Device confirmed removed from Entra ID after $elapsedTime minutes" "Green"
            return $true
        }
        
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-ColorOutput "Device still present in Entra ID after $elapsedTime minutes..." "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "⚠ Device still present in Entra ID after $MaxWaitMinutes minutes" "Red"
    return $false
}

# Function to verify device removal from Autopilot
function Test-AutopilotDeviceRemoved {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 10
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 30 # seconds
    
    Write-ColorOutput "Verifying device removal from Autopilot (max wait: $MaxWaitMinutes minutes)..." "Yellow"
    
    do {
        Start-Sleep -Seconds $checkInterval
        $device = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
        
        if (-not $device) {
            $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-ColorOutput "✓ Device confirmed removed from Autopilot after $elapsedTime minutes" "Green"
            return $true
        }
        
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        Write-ColorOutput "Device still present in Autopilot after $elapsedTime minutes..." "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "⚠ Device still present in Autopilot after $MaxWaitMinutes minutes" "Red"
    return $false
}

# Function to get device configuration profile assignments
function Get-DeviceConfigurationProfiles {
    param(
        [string]$DeviceId
    )
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId/deviceConfigurationStates"
        $configStates = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        
        $profiles = @()
        foreach ($state in $configStates) {
            if ($state.displayName) {
                $profiles += [PSCustomObject]@{
                    ProfileName = $state.displayName
                    State = $state.state
                    LastReportedDateTime = $state.lastReportedDateTime
                    Id = $state.id
                }
            }
        }
        
        return $profiles
    }
    catch {
        Write-ColorOutput "Error getting configuration profiles: $($_.Exception.Message)" "Red"
        return @()
    }
}

# Function to get device compliance policies
function Get-DeviceCompliancePolicies {
    param(
        [string]$DeviceId
    )
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$DeviceId/deviceCompliancePolicyStates"
        $complianceStates = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        
        $policies = @()
        foreach ($state in $complianceStates) {
            if ($state.displayName) {
                $policies += [PSCustomObject]@{
                    PolicyName = $state.displayName
                    State = $state.state
                    LastReportedDateTime = $state.lastReportedDateTime
                    Id = $state.id
                }
            }
        }
        
        return $policies
    }
    catch {
        Write-ColorOutput "Error getting compliance policies: $($_.Exception.Message)" "Red"
        return @()
    }
}

# Function to show current profile assignments for a device
function Show-DeviceProfileAssignments {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    
    Write-ColorOutput "Checking current profile assignments for device: $DeviceName" "Cyan"
    
    # Find the device in Intune
    $device = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    if (-not $device) {
        Write-ColorOutput "Device not found in Intune" "Red"
        return $false
    }
    
    Write-ColorOutput "Device found: $($device.deviceName) (ID: $($device.id))" "Green"
    Write-ColorOutput "Last sync: $($device.lastSyncDateTime)" "Gray"
    Write-ColorOutput "Compliance state: $($device.complianceState)" "Gray"
    Write-ColorOutput ""
    
    # Get configuration profiles
    $profiles = Get-DeviceConfigurationProfiles -DeviceId $device.id
    Write-ColorOutput "Configuration Profiles ($($profiles.Count)):" "White"
    if ($profiles.Count -eq 0) {
        Write-ColorOutput "  No configuration profiles assigned" "Gray"
    } else {
        foreach ($profile in $profiles) {
            $statusColor = switch ($profile.State) {
                "compliant" { "Green" }
                "nonCompliant" { "Red" }
                "error" { "Red" }
                "conflict" { "Yellow" }
                default { "Gray" }
            }
            Write-ColorOutput "  - $($profile.ProfileName)" "White"
            Write-ColorOutput "    State: $($profile.State)" $statusColor
            Write-ColorOutput "    Last reported: $($profile.LastReportedDateTime)" "Gray"
        }
    }
    
    Write-ColorOutput ""
    
    # Get compliance policies
    $policies = Get-DeviceCompliancePolicies -DeviceId $device.id
    Write-ColorOutput "Compliance Policies ($($policies.Count)):" "White"
    if ($policies.Count -eq 0) {
        Write-ColorOutput "  No compliance policies assigned" "Gray"
    } else {
        foreach ($policy in $policies) {
            $statusColor = switch ($policy.State) {
                "compliant" { "Green" }
                "nonCompliant" { "Red" }
                "error" { "Red" }
                "conflict" { "Yellow" }
                default { "Gray" }
            }
            Write-ColorOutput "  - $($policy.PolicyName)" "White"
            Write-ColorOutput "    State: $($policy.State)" $statusColor
            Write-ColorOutput "    Last reported: $($policy.LastReportedDateTime)" "Gray"
        }
    }
    
    $totalAssignments = $profiles.Count + $policies.Count
    Write-ColorOutput ""
    Write-ColorOutput "Total assignments: $totalAssignments" $(if ($totalAssignments -eq 0) { "Green" } else { "Yellow" })
    
    return $totalAssignments -eq 0
}

# Function to monitor profile assignments until they're removed
function Wait-ForProfileUnassignment {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 15
    )
    
    Write-ColorOutput "Monitoring profile assignments for device removal..." "Yellow"
    
    # First, get the device to monitor
    $device = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    if (-not $device) {
        Write-ColorOutput "Device not found in Intune - profiles already unassigned" "Green"
        return $true
    }
    
    # Get initial profile assignments
    $initialProfiles = Get-DeviceConfigurationProfiles -DeviceId $device.id
    $initialPolicies = Get-DeviceCompliancePolicies -DeviceId $device.id
    
    if ($initialProfiles.Count -eq 0 -and $initialPolicies.Count -eq 0) {
        Write-ColorOutput "No profiles or policies currently assigned" "Green"
        return $true
    }
    
    Write-ColorOutput "Initial assignments found:" "White"
    Write-ColorOutput "  Configuration Profiles: $($initialProfiles.Count)" "White"
    Write-ColorOutput "  Compliance Policies: $($initialPolicies.Count)" "White"
    
    foreach ($profile in $initialProfiles) {
        Write-ColorOutput "    - $($profile.ProfileName) ($($profile.State))" "Gray"
    }
    foreach ($policy in $initialPolicies) {
        Write-ColorOutput "    - $($policy.PolicyName) ($($policy.State))" "Gray"
    }
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 60 # seconds
    
    do {
        Start-Sleep -Seconds $checkInterval
        
        # Check if device still exists
        $currentDevice = Get-IntuneDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
        if (-not $currentDevice) {
            $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-ColorOutput "✓ Device removed from Intune - all profiles unassigned after $elapsedTime minutes" "Green"
            return $true
        }
        
        # Check current assignments
        $currentProfiles = Get-DeviceConfigurationProfiles -DeviceId $currentDevice.id
        $currentPolicies = Get-DeviceCompliancePolicies -DeviceId $currentDevice.id
        
        $totalAssignments = $currentProfiles.Count + $currentPolicies.Count
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        
        if ($totalAssignments -eq 0) {
            Write-ColorOutput "✓ All profiles and policies unassigned after $elapsedTime minutes" "Green"
            return $true
        }
        
        Write-ColorOutput "Still has $totalAssignments assignment(s) after $elapsedTime minutes (Profiles: $($currentProfiles.Count), Policies: $($currentPolicies.Count))" "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput "⚠ Device still has profile assignments after $MaxWaitMinutes minutes" "Red"
    return $false
}

# Function to monitor Autopilot device until it's removed
function Wait-ForAutopilotDeviceRemoval {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null,
        [int]$MaxWaitMinutes = 30
    )
    
    Write-ColorOutput "=================================================" "Magenta"
    Write-ColorOutput "    Monitoring Autopilot Device Removal" "Magenta"
    Write-ColorOutput "=================================================" "Magenta"
    Write-ColorOutput "Device: $DeviceName" "White"
    if ($SerialNumber) {
        Write-ColorOutput "Serial: $SerialNumber" "White"
    }
    Write-ColorOutput "Maximum monitoring time: $MaxWaitMinutes minutes" "Yellow"
    Write-ColorOutput ""
    
    # First check if device exists
    $device = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
    if (-not $device) {
        Write-ColorOutput "✓ Device is not present in Autopilot" "Green"
        return $true
    }
    
    Write-ColorOutput "Device found in Autopilot:" "Yellow"
    Write-ColorOutput "  Name: $($device.displayName)" "White"
    Write-ColorOutput "  Serial: $($device.serialNumber)" "White"
    Write-ColorOutput "  Model: $($device.model)" "White"
    Write-ColorOutput "  ID: $($device.id)" "Gray"
    Write-ColorOutput ""
    Write-ColorOutput "Starting monitoring... (checking every 30 seconds)" "Yellow"
    Write-ColorOutput ""
    
    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($MaxWaitMinutes)
    $checkInterval = 30 # seconds
    $checkCount = 0
    
    do {
        Start-Sleep -Seconds $checkInterval
        $checkCount++
        
        $currentDevice = Get-AutopilotDevice -DeviceName $DeviceName -SerialNumber $SerialNumber
        $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
        
        if (-not $currentDevice) {
            Write-ColorOutput ""
            Write-ColorOutput "🎉 SUCCESS! Device removed from Autopilot after $elapsedTime minutes" "Green"
            Write-ColorOutput "   Total checks performed: $checkCount" "Gray"
            Write-ColorOutput "   Removal confirmed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Gray"
            
            # Play a notification sound (if available)
            try {
                [System.Console]::Beep(800, 500)
                [System.Console]::Beep(1000, 500)
                [System.Console]::Beep(1200, 1000)
            } catch {
                # Ignore if beep is not available
            }
            
            return $true
        }
        
        Write-ColorOutput "[$checkCount] Device still present after $elapsedTime minutes..." "Yellow"
        
    } while ((Get-Date) -lt $endTime)
    
    Write-ColorOutput ""
    Write-ColorOutput "⚠ Device still present in Autopilot after $MaxWaitMinutes minutes" "Red"
    Write-ColorOutput "   Total checks performed: $checkCount" "Gray"
    Write-ColorOutput "   You may want to check manually or extend the monitoring time" "Yellow"
    
    return $false
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
} else {
    Write-ColorOutput "Automatic monitoring enabled: Checks every 5 seconds after removal" "Cyan"
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

# Silently open selection grid

# Show interactive grid for device selection
$selectedDevices = $enrichedDevices | Select-Object DisplayName, SerialNumber, Model, Manufacturer, GroupTag, DeploymentProfile, IntuneFound, EntraFound, IntuneName, EntraName | Out-GridView -Title "Select Devices to Remove from All Services" -PassThru

if (-not $selectedDevices -or $selectedDevices.Count -eq 0) {
    Write-ColorOutput "No devices selected. Exiting." "Yellow"
    exit 0
}

# Process selected devices silently

# Process each selected device with enhanced logic
$results = @()
foreach ($selectedDevice in $selectedDevices) {
    # Find the full device info
    $fullDevice = $enrichedDevices | Where-Object { $_.SerialNumber -eq $selectedDevice.SerialNumber }
    $deviceName = $fullDevice.DisplayName
    $serialNumber = $fullDevice.SerialNumber
    
    # Process device silently
    
    $deviceResult = [PSCustomObject]@{
        SerialNumber = $serialNumber
        DisplayName = $deviceName
        EntraID = @{ Found = $false; Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
        Intune = @{ Found = $false; Success = $false; Error = $null }
        Autopilot = @{ Found = $false; Success = $false; Error = $null }
    }
    
    # Remove from Intune first (management layer) - silently
    $intuneResult = Remove-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Intune.Found = $intuneResult.Found
    $deviceResult.Intune.Success = $intuneResult.Success
    $deviceResult.Intune.Error = $intuneResult.Error
    
    # Remove from Autopilot second (deployment service) - silently
    $autopilotResult = Remove-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
    $deviceResult.Autopilot.Found = $autopilotResult.Found
    $deviceResult.Autopilot.Success = $autopilotResult.Success
    $deviceResult.Autopilot.Error = $autopilotResult.Error
    
    # Remove from Entra ID last (identity source) - silently
    $entraDevices = Get-EntraDeviceByName -DeviceName $deviceName -SerialNumber $serialNumber
    if ($entraDevices -and $entraDevices.Count -gt 0) {
        $deviceResult.EntraID.Found = $true
        $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $deviceName -SerialNumber $serialNumber
        $deviceResult.EntraID.Success = $entraResult.Success
        $deviceResult.EntraID.DeletedCount = $entraResult.DeletedCount
        $deviceResult.EntraID.FailedCount = $entraResult.FailedCount
        $deviceResult.EntraID.Errors = $entraResult.Errors
    }
    
    # Automatic monitoring after deletion (not in WhatIf mode)
    if (-not $WhatIf -and ($deviceResult.Autopilot.Success -or $deviceResult.Intune.Success -or $deviceResult.EntraID.Success)) {
        Write-ColorOutput ""
        
        $startTime = Get-Date
        $maxMonitorMinutes = 30 # Maximum monitoring time
        $endTime = $startTime.AddMinutes($maxMonitorMinutes)
        $checkInterval = 5 # seconds
        
        $autopilotRemoved = -not $deviceResult.Autopilot.Success
        $intuneRemoved = -not $deviceResult.Intune.Success
        $entraRemoved = -not $deviceResult.EntraID.Success
        
        # Count devices to monitor
        $devicesToMonitor = 0
        if (-not $autopilotRemoved) { $devicesToMonitor++ }
        if (-not $intuneRemoved) { $devicesToMonitor++ }
        if (-not $entraRemoved) { $devicesToMonitor++ }
        
        # Show initial device found messages
        if ($deviceResult.Intune.Found) {
            Write-ColorOutput "Found Intune device by serial number: $serialNumber" "White"
            Write-ColorOutput ""
            Write-ColorOutput "Found Device in Intune" "Green"
            Write-ColorOutput ""
        }
        
        do {
            Start-Sleep -Seconds $checkInterval
            
            # Set monitoring mode to suppress verbose messages
            $script:MonitoringMode = $true
            
            # Check Intune status first
            if (-not $intuneRemoved) {
                Write-ColorOutput "Waiting for 1 of 1 to be removed from Intune" "Yellow"
                $intuneDevice = Get-IntuneDevice -DeviceName $deviceName -SerialNumber $serialNumber
                if (-not $intuneDevice) {
                    $intuneRemoved = $true
                    Write-ColorOutput ""
                    Write-ColorOutput "1 Device Successfully Removed from Intune" "Green"
                    Write-ColorOutput ""
                    $deviceResult.Intune.Verified = $true
                    
                    # Show Autopilot found message after Intune is removed
                    if ($deviceResult.Autopilot.Found) {
                        Write-ColorOutput "Found Device in Autopilot" "Green"
                        Write-ColorOutput ""
                    }
                }
            }
            
            # Check Autopilot status (only after Intune is removed)
            if ($intuneRemoved -and -not $autopilotRemoved) {
                Write-ColorOutput "Waiting for 1 of 1 to be removed from Autopilot" "Yellow"
                $autopilotDevice = Get-AutopilotDevice -DeviceName $deviceName -SerialNumber $serialNumber
                if (-not $autopilotDevice) {
                    $autopilotRemoved = $true
                    Write-ColorOutput ""
                    Write-ColorOutput "1 Device Successfully Removed from Autopilot" "Green"
                    Write-ColorOutput ""
                    $deviceResult.Autopilot.Verified = $true
                }
            }
            
            # Exit if both Intune and Autopilot are removed (skip Entra ID monitoring)
            if ($autopilotRemoved -and $intuneRemoved) {
                $elapsedTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
                
                # Get device object ID from the original device data
                $deviceObjectId = "N/A"
                $fullDeviceData = $enrichedDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
                if ($fullDeviceData -and $fullDeviceData.EntraId) {
                    $deviceObjectId = $fullDeviceData.EntraId
                } elseif ($fullDeviceData -and $fullDeviceData.IntuneId) {
                    $deviceObjectId = $fullDeviceData.IntuneId
                } elseif ($fullDeviceData -and $fullDeviceData.AutopilotId) {
                    $deviceObjectId = $fullDeviceData.AutopilotId
                }
                
                Write-ColorOutput "Device Serial Number: $serialNumber" "White"
                Write-ColorOutput "Device Object ID: $deviceObjectId" "White"
                Write-ColorOutput ""
                Write-ColorOutput "Removed from Autopilot, Intune, and Entra ID" "Green"
                
                # Play success notification
                try {
                    [System.Console]::Beep(800, 300)
                    [System.Console]::Beep(1000, 300)
                    [System.Console]::Beep(1200, 500)
                } catch { }
                
                break
            }
            
        } while ((Get-Date) -lt $endTime)
        
    }
    
    $results += $deviceResult
}

# Script completes silently - no summary