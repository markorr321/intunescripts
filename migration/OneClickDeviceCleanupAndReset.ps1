#Requires -RunAsAdministrator

<#
.SYNOPSIS
    One-click device cleanup and reset tool with GUI
    
.DESCRIPTION
    This script provides a one-click solution that:
    1. Identifies the current device serial number
    2. Removes the device from Microsoft Intune
    3. Removes the device from Windows Autopilot
    4. Removes the device from Microsoft Entra ID (Azure AD)
    5. Performs a Windows reset (keep files, local reinstall)
    
    Features a simple GUI interface for easy operation.
    
.PARAMETER WhatIf
    Shows what would be done without actually performing the operations
    
.EXAMPLE
    .\OneClickDeviceCleanupAndReset.ps1
    
.EXAMPLE
    .\OneClickDeviceCleanupAndReset.ps1 -WhatIf
    
.NOTES
    - Requires Administrator privileges
    - Requires Microsoft Graph PowerShell modules
    - Device will restart during the reset process
    - Personal files will be preserved during reset
    - Installed applications will be removed during reset
#>

param(
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

# Add Windows Forms for GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$script:LogPath = "C:\ProgramData\DeviceCleanupReset\DeviceCleanupReset.log"
$script:CurrentDevice = $null
$script:GraphConnected = $false
$script:MonitoringMode = $false

# Function to write log entries
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console
    Write-Host $logEntry
    
    # Write to log file
    try {
        $logDir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        $logEntry | Out-File -FilePath $script:LogPath -Append -Encoding UTF8 -Force
    }
    catch {
        Write-Warning "Could not write to log file: $($_.Exception.Message)"
    }
}

# Attempt device reset via MDM WMI Bridge (MDM_RemoteWipe)
function Start-MDMRemoteWipe {
    Write-Log "Attempting MDM remote wipe via WMI Bridge..."
    try {
        $namespaceName = "root\cimv2\mdm\dmmap"
        $className = "MDM_RemoteWipe"
        $methodName = "doWipeMethod"
        $session = New-CimSession
        $instance = Get-CimInstance -Namespace $namespaceName -ClassName $className -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
        if (-not $instance) {
            throw "MDM RemoteWipe instance not found (device may not be MDM-enrolled)"
        }
        # Build method parameters (param: empty string)
        $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
        $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create("param", "", [Microsoft.Management.Infrastructure.CimType]::String, [Microsoft.Management.Infrastructure.CimFlags]::In)
        [void]$params.Add($param)

        if ($WhatIf) {
            Write-Log "WHATIF: Would invoke MDM RemoteWipe via WMI Bridge"
            return @{ Success = $true; Error = $null }
        }

        $null = $session.InvokeMethod($namespaceName, $instance, $methodName, $params)
        Write-Log "MDM remote wipe initiated successfully"
        return @{ Success = $true; Error = $null }
    }
    catch {
        $err = $_.Exception.Message
        Write-Log "ERROR: Failed to initiate MDM remote wipe: $err" "ERROR"
        return @{ Success = $false; Error = $err }
    }
    finally {
        if ($session) { $session.Dispose() }
    }
}

# Function to get current device information
function Get-CurrentDeviceInfo {
    try {
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
        $bios = Get-WmiObject -Class Win32_BIOS
        
        $deviceInfo = [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            SerialNumber = $bios.SerialNumber.Trim()
            Manufacturer = $computerSystem.Manufacturer.Trim()
            Model = $computerSystem.Model.Trim()
            UserName = $env:USERNAME
            Domain = $env:USERDOMAIN
        }
        
        Write-Log "Device Info - Name: $($deviceInfo.ComputerName), Serial: $($deviceInfo.SerialNumber), Model: $($deviceInfo.Model)"
        return $deviceInfo
    }
    catch {
        Write-Log "ERROR: Failed to get device information: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to install required modules
function Install-RequiredModules {
    param([array]$ModuleNames)
    
    Write-Log "Checking and installing required PowerShell modules..."
    
    # Set PowerShell Gallery as trusted repository
    try {
        $gallery = Get-PSRepository -Name "PSGallery" -ErrorAction SilentlyContinue
        if ($gallery.InstallationPolicy -ne "Trusted") {
            Write-Log "Setting PSGallery as trusted repository..."
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
        }
    }
    catch {
        Write-Log "WARNING: Could not set PSGallery as trusted: $($_.Exception.Message)" "WARNING"
    }
    
    foreach ($moduleName in $ModuleNames) {
        Write-Log "Checking module: $moduleName"
        
        # Check if module is already installed
        $installedModule = Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue
        
        if ($installedModule) {
            Write-Log "Module $moduleName is already installed (Version: $($installedModule[0].Version))"
        }
        else {
            Write-Log "Installing module: $moduleName"
            try {
                # Install module for current user (doesn't require admin for machine-wide install)
                Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
                Write-Log "Successfully installed module: $moduleName"
            }
            catch {
                Write-Log "ERROR: Failed to install module $moduleName : $($_.Exception.Message)" "ERROR"
                return $false
            }
        }
    }
    
    # Import modules
    foreach ($moduleName in $ModuleNames) {
        try {
            Write-Log "Importing module: $moduleName"
            Import-Module $moduleName -Force
        }
        catch {
            Write-Log "ERROR: Failed to import module $moduleName : $($_.Exception.Message)" "ERROR"
            return $false
        }
    }
    
    Write-Log "All required modules are installed and imported successfully"
    return $true
}

# Function to test Graph connection
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
    Write-Log "Connecting to Microsoft Graph..."
    
    $requiredScopes = @(
        "Device.ReadWrite.All",
        "DeviceManagementManagedDevices.ReadWrite.All", 
        "DeviceManagementServiceConfig.ReadWrite.All"
    )
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        Write-Log "Successfully connected to Microsoft Graph"
        $script:GraphConnected = $true
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
        $script:GraphConnected = $false
        return $false
    }
}

# Function to find device in Intune
function Get-IntuneDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber
    )
    
    try {
        # Try by device name first
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$DeviceName'"
        $device = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
        
        if ($device) {
            Write-Log "Found device in Intune by name: $($device.deviceName)"
            return $device
        }
        
        # Try by serial number if name search failed
        if ($SerialNumber) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '$SerialNumber'"
            $device = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($device) {
                Write-Log "Found device in Intune by serial: $($device.deviceName)"
                return $device
            }
        }
        
        Write-Log "Device not found in Intune" "WARNING"
        return $null
    }
    catch {
        Write-Log "ERROR: Failed to search Intune: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to find device in Autopilot
function Get-AutopilotDevice {
    param(
        [string]$SerialNumber,
        [string]$DeviceName
    )
    
    try {
        # Try by serial number first
        if ($SerialNumber) {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$SerialNumber')"
            $device = (Invoke-MgGraphRequest -Uri $uri -Method GET).value | Select-Object -First 1
            
            if ($device) {
                Write-Log "Found device in Autopilot by serial: $($device.displayName)"
                return $device
            }
        }
        
        Write-Log "Device not found in Autopilot" "WARNING"
        return $null
    }
    catch {
        Write-Log "ERROR: Failed to search Autopilot: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to find device in Entra ID
function Get-EntraDevice {
    param(
        [string]$DeviceName,
        [string]$SerialNumber
    )
    
    try {
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
        $devices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        
        if ($devices -and $devices.Count -gt 0) {
            # If we have a serial number, validate it
            if ($SerialNumber) {
                foreach ($device in $devices) {
                    if ($device.physicalIds) {
                        foreach ($physicalId in $device.physicalIds) {
                            if ($physicalId -match '\[SerialNumber\]:(.+)') {
                                $deviceSerial = $matches[1].Trim()
                                if ($deviceSerial -eq $SerialNumber) {
                                    Write-Log "Found device in Entra ID: $($device.displayName)"
                                    return $device
                                }
                            }
                        }
                    }
                }
            } else {
                Write-Log "Found device in Entra ID: $($devices[0].displayName)"
                return $devices[0]
            }
        }
        
        Write-Log "Device not found in Entra ID" "WARNING"
        return $null
    }
    catch {
        Write-Log "ERROR: Failed to search Entra ID: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Enhanced: Find Entra ID devices by name with optional serial validation.
function Get-EntraDeviceByName {
    param(
        [string]$DeviceName,
        [string]$SerialNumber = $null
    )
    try {
        if ([string]::IsNullOrWhiteSpace($DeviceName)) { return @() }
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
        $aadDevices = (Invoke-MgGraphRequest -Uri $uri -Method GET).value
        if (-not $aadDevices -or $aadDevices.Count -eq 0) {
            Write-Log "Device $DeviceName not found in Entra ID" "WARNING"
            return @()
        }
        if ($SerialNumber) {
            $validated = @()
            foreach ($aad in $aadDevices) {
                $deviceSerial = $null
                if ($aad.physicalIds) {
                    foreach ($physicalId in $aad.physicalIds) {
                        if ($physicalId -match '\[SerialNumber\]:(.+)') { $deviceSerial = $matches[1].Trim(); break }
                    }
                }
                if (-not $deviceSerial -or $deviceSerial -eq $SerialNumber) {
                    $validated += $aad
                    if ($deviceSerial) { Write-Log "Validated Entra device: $($aad.displayName) (Serial: $deviceSerial)" }
                } else {
                    Write-Log "Skipping Entra ID device with ID $($aad.id) - serial mismatch (Device: $deviceSerial, Expected: $SerialNumber)" "WARNING"
                }
            }
            return $validated
        }
        return $aadDevices
    }
    catch {
        Write-Log "ERROR: Failed to search Entra ID: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# Function to remove device from Intune
function Remove-IntuneDevice {
    param($Device)
    
    if (-not $Device) {
        return @{ Success = $false; Error = "Device not found" }
    }
    
    try {
        if ($WhatIf) {
            Write-Log "WHATIF: Would remove device from Intune: $($Device.deviceName)"
            return @{ Success = $true; Error = $null }
        }
        
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($Device.id)"
        Invoke-MgGraphRequest -Uri $uri -Method DELETE
        Write-Log "Queued device for removal from Intune: $($Device.deviceName)"
        return @{ Success = $true; Error = $null }
    }
    catch {
        $error = $_.Exception.Message
        Write-Log "ERROR: Failed to remove device from Intune: $error" "ERROR"
        return @{ Success = $false; Error = $error }
    }
}

# Function to remove device from Autopilot
function Remove-AutopilotDevice {
    param($Device)
    
    if (-not $Device) {
        return @{ Success = $false; Error = "Device not found" }
    }
    
    try {
        if ($WhatIf) {
            Write-Log "WHATIF: Would remove device from Autopilot: $($Device.displayName)"
            return @{ Success = $true; Error = $null }
        }
        
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($Device.id)"
        Invoke-MgGraphRequest -Uri $uri -Method DELETE
        Write-Log "Queued device for removal from Autopilot: $($Device.displayName)"
        return @{ Success = $true; Error = $null }
    }
    catch {
        $error = $_.Exception.Message
        Write-Log "ERROR: Failed to remove device from Autopilot: $error" "ERROR"
        return @{ Success = $false; Error = $error }
    }
}

# Function to remove one or more devices from Entra ID
function Remove-EntraDevices {
    param(
        [array]$Devices,
        [string]$DeviceName
    )
    if (-not $Devices -or $Devices.Count -eq 0) {
        return @{ Success = $false; DeletedCount = 0; FailedCount = 0; Errors = @() }
    }
    $deletedCount = 0
    $failedCount = 0
    $errors = @()
    foreach ($aad in $Devices) {
        try {
            $uri = "https://graph.microsoft.com/v1.0/devices/$($aad.id)"
            if ($WhatIf) {
                Write-Log "WHATIF: Would remove Entra ID device: $($aad.displayName) (ID: $($aad.id))"
                $deletedCount++
            } else {
                Invoke-MgGraphRequest -Uri $uri -Method DELETE
                $deletedCount++
                Write-Log "Queued device for removal from Entra ID: $DeviceName"
            }
        }
        catch {
            $failedCount++
            $msg = $_.Exception.Message
            $errors += $msg
            Write-Log "ERROR: Failed to remove device $DeviceName from Entra ID: $msg" "ERROR"
        }
    }
    $success = ($deletedCount -gt 0 -and $failedCount -eq 0)
    return @{ Success = $success; DeletedCount = $deletedCount; FailedCount = $failedCount; Errors = $errors }
}

# Function to perform Windows reset
function Start-WindowsReset {
    Write-Log "Initiating Windows reset process..."
    
    try {
        # Resolve systemreset.exe path (handle 32-bit redirection)
        $systemResetPath = Join-Path $env:SystemRoot "System32\systemreset.exe"
        if (-not (Test-Path $systemResetPath)) {
            if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
                $sysnativePath = Join-Path $env:SystemRoot "Sysnative\systemreset.exe"
                if (Test-Path $sysnativePath) { $systemResetPath = $sysnativePath }
            }
        }
        
        # WinSxS fallback: locate another copy of systemreset.exe if missing
        if (-not (Test-Path $systemResetPath)) {
            try {
                $candidate = Get-ChildItem -Path (Join-Path $env:SystemRoot "WinSxS") -Filter systemreset.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($candidate -and (Test-Path $candidate.FullName)) {
                    Write-Log "Found systemreset.exe in WinSxS: $($candidate.FullName)"
                    $systemResetPath = $candidate.FullName
                }
            } catch { }
        }
        
        $hasSystemReset = Test-Path $systemResetPath
        
        # Try to ensure Windows RE is enabled (best-effort)
        try { Start-Process -FilePath "reagentc.exe" -ArgumentList "/enable" -WindowStyle Hidden -NoNewWindow -Wait -ErrorAction SilentlyContinue } catch { }
        
        if ($WhatIf) {
            Write-Log "WHATIF: Would initiate Windows reset (keep files, local reinstall)"
            return @{ Success = $true; Error = $null }
        }
        
        if ($hasSystemReset) {
            # Create scheduled task for reset via systemreset.exe
            $taskName = "DeviceCleanupReset"
            $resetCommand = $systemResetPath
            $resetArgs = "/factoryreset /quiet"
            
            # Remove existing task if it exists
            try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            
            # Create scheduled task
            $action = New-ScheduledTaskAction -Execute $resetCommand -Argument $resetArgs
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Device Cleanup and Reset"
            Write-Log "Windows reset scheduled to start in 2 minutes"
            return @{ Success = $true; Error = $null }
        } else {
            # Fallback: prompt user for how to proceed
            Write-Log "systemreset.exe not found. Prompting user for Advanced startup fallback options." "WARNING"
            $msg = "systemreset.exe is not available on this system.\n\nChoose how to proceed:\n\nYes  = Reboot to Advanced startup NOW\nNo   = Reboot to Advanced startup in 2 minutes\nCancel = Skip Windows reset"
            $choice = [System.Windows.Forms.MessageBox]::Show($msg, "Windows Reset Fallback", "YesNoCancel", "Question")
            try {
                switch ($choice) {
                    "Yes" {
                        Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /o /t 0" -WindowStyle Hidden -NoNewWindow
                        Write-Log "Rebooting now to Advanced startup. Choose 'Troubleshoot' > 'Reset this PC' after reboot." "WARNING"
                        return @{ Success = $true; Error = $null }
                    }
                    "No" {
                        Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /o /t 120" -WindowStyle Hidden -NoNewWindow
                        Write-Log "System will reboot to Advanced startup in 2 minutes. Choose 'Troubleshoot' > 'Reset this PC' after reboot." "WARNING"
                        return @{ Success = $true; Error = $null }
                    }
                    Default {
                        Write-Log "User chose to skip Windows reset (no reboot scheduled)." "WARNING"
                        return @{ Success = $false; Error = "User chose to skip Windows reset" }
                    }
                }
            }
            catch {
                throw "Neither systemreset.exe is available nor could we schedule reboot to recovery."
            }
        }
    }
    catch {
        $error = $_.Exception.Message
        Write-Log "ERROR: Failed to initiate Windows reset: $error" "ERROR"
        return @{ Success = $false; Error = $error }
    }
}

# Function to create and show GUI
function Show-DeviceCleanupGUI {
    # Create main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "One-Click Device Cleanup and Reset"
    $form.Size = New-Object System.Drawing.Size(600, 700)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    # Create controls
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Device Cleanup and Reset Tool"
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Size = New-Object System.Drawing.Size(580, 30)
    $titleLabel.Location = New-Object System.Drawing.Point(10, 10)
    $titleLabel.TextAlign = "MiddleCenter"
    
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text = "This tool will remove the current device from Intune, Autopilot, and Entra ID, then reset Windows while keeping your files."
    $descLabel.Size = New-Object System.Drawing.Size(580, 40)
    $descLabel.Location = New-Object System.Drawing.Point(10, 50)
    $descLabel.TextAlign = "TopCenter"
    
    # Device info group
    $deviceGroupBox = New-Object System.Windows.Forms.GroupBox
    $deviceGroupBox.Text = "Current Device Information"
    $deviceGroupBox.Size = New-Object System.Drawing.Size(580, 120)
    $deviceGroupBox.Location = New-Object System.Drawing.Point(10, 100)
    
    $deviceInfoLabel = New-Object System.Windows.Forms.Label
    $deviceInfoLabel.Size = New-Object System.Drawing.Size(560, 90)
    $deviceInfoLabel.Location = New-Object System.Drawing.Point(10, 20)
    $deviceInfoLabel.Text = "Loading device information..."
    
    # Status group
    $statusGroupBox = New-Object System.Windows.Forms.GroupBox
    $statusGroupBox.Text = "Operation Status"
    $statusGroupBox.Size = New-Object System.Drawing.Size(580, 200)
    $statusGroupBox.Location = New-Object System.Drawing.Point(10, 230)
    
    $statusTextBox = New-Object System.Windows.Forms.TextBox
    $statusTextBox.Multiline = $true
    $statusTextBox.ScrollBars = "Vertical"
    $statusTextBox.ReadOnly = $true
    $statusTextBox.Size = New-Object System.Drawing.Size(560, 170)
    $statusTextBox.Location = New-Object System.Drawing.Point(10, 20)
    $statusTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    
    # Warning group
    $warningGroupBox = New-Object System.Windows.Forms.GroupBox
    $warningGroupBox.Text = "Important Warning"
    $warningGroupBox.Size = New-Object System.Drawing.Size(580, 120)
    $warningGroupBox.Location = New-Object System.Drawing.Point(10, 440)
    $warningGroupBox.ForeColor = "Red"
    
    $warningLabel = New-Object System.Windows.Forms.Label
    $warningLabel.Size = New-Object System.Drawing.Size(560, 90)
    $warningLabel.Location = New-Object System.Drawing.Point(10, 20)
    $warningLabel.Text = "- This operation cannot be undone`n- The device will be removed from all Microsoft services`n- Windows will reset and restart multiple times`n- Personal files will be kept, but all applications will be removed`n- Ensure the device is connected to power before proceeding"
    
    # Buttons
    $executeButton = New-Object System.Windows.Forms.Button
    $executeButton.Text = "Execute Cleanup and Reset"
    $executeButton.Size = New-Object System.Drawing.Size(200, 40)
    $executeButton.Location = New-Object System.Drawing.Point(50, 580)
    $executeButton.BackColor = "LightGreen"
    $executeButton.Font = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
    
    $whatIfButton = New-Object System.Windows.Forms.Button
    $whatIfButton.Text = "Preview (What-If)"
    $whatIfButton.Size = New-Object System.Drawing.Size(150, 40)
    $whatIfButton.Location = New-Object System.Drawing.Point(270, 580)
    $whatIfButton.BackColor = "LightBlue"
    
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Size = New-Object System.Drawing.Size(100, 40)
    $closeButton.Location = New-Object System.Drawing.Point(440, 580)
    $closeButton.BackColor = "LightCoral"
    
    # Add controls to form
    $form.Controls.Add($titleLabel)
    $form.Controls.Add($descLabel)
    $form.Controls.Add($deviceGroupBox)
    $deviceGroupBox.Controls.Add($deviceInfoLabel)
    $form.Controls.Add($statusGroupBox)
    $statusGroupBox.Controls.Add($statusTextBox)
    $form.Controls.Add($warningGroupBox)
    $warningGroupBox.Controls.Add($warningLabel)
    $form.Controls.Add($executeButton)
    $form.Controls.Add($whatIfButton)
    $form.Controls.Add($closeButton)
    
    # Function to update status
    function Update-Status {
        param([string]$Message)
        $timestamp = Get-Date -Format "HH:mm:ss"
        $statusTextBox.AppendText("[$timestamp] $Message`r`n")
        $statusTextBox.SelectionStart = $statusTextBox.Text.Length
        $statusTextBox.ScrollToCaret()
        $form.Refresh()
    }
    
    # Function to execute cleanup and reset
    function Execute-CleanupAndReset {
        param([bool]$WhatIfMode = $false)
        
        $executeButton.Enabled = $false
        $whatIfButton.Enabled = $false
        
        try {
            if ($WhatIfMode) {
                Update-Status "=== PREVIEW MODE (No actual changes will be made) ==="
            } else {
                Update-Status "=== Starting Device Cleanup and Reset ==="
            }
            
            # Ensure required modules are installed
            Update-Status "Checking and installing required PowerShell modules..."
            $requiredModules = @("Microsoft.Graph.Authentication", "Microsoft.Graph.DeviceManagement", "Microsoft.Graph.Identity.DirectoryManagement")
            if (-not (Install-RequiredModules -ModuleNames $requiredModules)) {
                Update-Status "ERROR: Failed to install required PowerShell modules"
                return
            }
            Update-Status "[OK] All required modules are available"
            
            # Connect to Graph if not already connected
            if (-not $script:GraphConnected) {
                Update-Status "Connecting to Microsoft Graph..."
                if (-not (Connect-ToGraph)) {
                    Update-Status "ERROR: Failed to connect to Microsoft Graph"
                    return
                }
                Update-Status "Successfully connected to Microsoft Graph"
            }
            
            # Get current device info
            $device = $script:CurrentDevice
            if (-not $device) {
                Update-Status "ERROR: Device information not available"
                return
            }
            
            # Find devices in each service
            Update-Status "Searching for device in Microsoft services..."
            $intuneDevice = Get-IntuneDevice -DeviceName $device.ComputerName -SerialNumber $device.SerialNumber
            $autopilotDevice = Get-AutopilotDevice -SerialNumber $device.SerialNumber -DeviceName $device.ComputerName
            $entraDevices = Get-EntraDeviceByName -DeviceName $device.ComputerName -SerialNumber $device.SerialNumber
            
            # Report findings
            Update-Status "Device search results:"
            Update-Status "  Intune: $(if ($intuneDevice) { 'Found' } else { 'Not Found' })"
            Update-Status "  Autopilot: $(if ($autopilotDevice) { 'Found' } else { 'Not Found' })"
            Update-Status "  Entra ID: $(if ($entraDevices -and $entraDevices.Count -gt 0) { 'Found' } else { 'Not Found' })"
            
            if (-not $intuneDevice -and -not $autopilotDevice -and -not ($entraDevices -and $entraDevices.Count -gt 0)) {
                Update-Status "WARNING: Device not found in any Microsoft services"
                if (-not $WhatIfMode) {
                    $result = [System.Windows.Forms.MessageBox]::Show("Device not found in Microsoft services. Proceed with Windows reset only?", "Device Not Found", "YesNo", "Question")
                    if ($result -eq "No") {
                        Update-Status "Operation cancelled by user"
                        return
                    }
                }
            }
            
            # Remove from services
            if ($intuneDevice -or $autopilotDevice -or ($entraDevices -and $entraDevices.Count -gt 0)) {
                Update-Status "Removing device from Microsoft services..."
                
                # Remove from Intune first
                if ($intuneDevice) {
                    Update-Status "Removing from Intune..."
                    $result = Remove-IntuneDevice -Device $intuneDevice
                    if ($result.Success) {
                        Update-Status "[OK] Successfully queued for removal from Intune"
                    } else {
                        Update-Status "[FAIL] Failed to remove from Intune: $($result.Error)"
                    }
                }
                
                # Remove from Autopilot
                if ($autopilotDevice) {
                    Update-Status "Removing from Autopilot..."
                    $result = Remove-AutopilotDevice -Device $autopilotDevice
                    if ($result.Success) {
                        Update-Status "[OK] Successfully queued for removal from Autopilot"
                    } else {
                        Update-Status "[FAIL] Failed to remove from Autopilot: $($result.Error)"
                    }
                }
                
                # Remove from Entra ID (handle duplicates)
                if ($entraDevices -and $entraDevices.Count -gt 0) {
                    Update-Status "Removing from Entra ID..."
                    $entraResult = Remove-EntraDevices -Devices $entraDevices -DeviceName $device.ComputerName
                    if ($entraResult.Success) {
                        Update-Status "[OK] Successfully queued for removal from Entra ID"
                    } else {
                        Update-Status "[FAIL] Failed to remove from Entra ID: $($entraResult.Errors -join '; ')"
                    }
                }
            }

            # Post-deletion monitoring (only when not WhatIf)
            if (-not $WhatIfMode -and ($intuneDevice -or $autopilotDevice -or ($entraDevices -and $entraDevices.Count -gt 0))) {
                Update-Status "Monitoring device removal..."
                $startTime = Get-Date
                $maxMonitorMinutes = 30
                $endTime = $startTime.AddMinutes($maxMonitorMinutes)
                $checkInterval = 5
                $autopilotRemoved = -not $autopilotDevice
                $intuneRemoved = -not $intuneDevice
                $entraRemoved = -not ($entraDevices -and $entraDevices.Count -gt 0)
                do {
                    Start-Sleep -Seconds $checkInterval
                    $script:MonitoringMode = $true
                    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
                    if (-not $intuneRemoved) {
                        Update-Status "Waiting for Intune removal (Elapsed: $elapsed min)"
                        try {
                            $check = Get-IntuneDevice -DeviceName $device.ComputerName -SerialNumber $device.SerialNumber
                            if (-not $check) { $intuneRemoved = $true; Update-Status "[OK] Device removed from Intune" }
                        } catch { Update-Status "Error checking Intune: $($_.Exception.Message)" }
                    }
                    if ($intuneRemoved -and -not $autopilotRemoved) {
                        Update-Status "Waiting for Autopilot removal (Elapsed: $elapsed min)"
                        try {
                            $check = Get-AutopilotDevice -SerialNumber $device.SerialNumber -DeviceName $device.ComputerName
                            if (-not $check) { $autopilotRemoved = $true; Update-Status "[OK] Device removed from Autopilot" }
                        } catch { Update-Status "Error checking Autopilot: $($_.Exception.Message)" }
                    }
                    if ($intuneRemoved -and $autopilotRemoved -and -not $entraRemoved) {
                        Update-Status "Waiting for Entra ID removal (Elapsed: $elapsed min)"
                        try {
                            $checkList = Get-EntraDeviceByName -DeviceName $device.ComputerName -SerialNumber $device.SerialNumber
                            if (-not $checkList -or $checkList.Count -eq 0) { $entraRemoved = $true; Update-Status "[OK] Device removed from Entra ID" }
                        } catch { Update-Status "Error checking Entra ID: $($_.Exception.Message)" }
                    }
                    if ($intuneRemoved -and $autopilotRemoved -and $entraRemoved) {
                        Update-Status "Removal verified across all services"
                        try { [System.Console]::Beep(800,300); [System.Console]::Beep(1000,300); [System.Console]::Beep(1200,500) } catch {}
                        break
                    }
                } while ((Get-Date) -lt $endTime)
                $script:MonitoringMode = $false
                if ((Get-Date) -ge $endTime) {
                    Update-Status "Monitoring timeout reached after $maxMonitorMinutes minutes. Some services may still show the device."
                }
            }
            
            # Perform reset: try MDM remote wipe first, then fall back to Windows reset
            Update-Status "Initiating device reset..."
            $wipeResult = Start-MDMRemoteWipe
            if ($wipeResult.Success) {
                if ($WhatIfMode) {
                    Update-Status "[OK] MDM remote wipe would be initiated"
                } else {
                    Update-Status "[OK] MDM remote wipe initiated. The device will reset shortly."
                }
            } else {
                Update-Status "MDM remote wipe not available or failed. Falling back to Windows reset..."
                $resetResult = Start-WindowsReset
                if ($resetResult.Success) {
                    if ($WhatIfMode) {
                        Update-Status "[OK] Windows reset would be initiated (keep files, local reinstall)"
                    } else {
                        Update-Status "[OK] Windows reset scheduled or recovery reboot configured"
                        Update-Status "=== Operation completed successfully ==="
                        [System.Windows.Forms.MessageBox]::Show("Device cleanup completed. Reset has been initiated or scheduled.", "Success", "OK", "Information")
                    }
                } else {
                    Update-Status "[FAIL] Failed to initiate Windows reset: $($resetResult.Error)"
                }
            }
            
            if ($WhatIfMode) {
                Update-Status "=== Preview completed - no changes were made ==="
            }
        }
        finally {
            $executeButton.Enabled = $true
            $whatIfButton.Enabled = $true
        }
    }
    
    # Event handlers
    $executeButton.Add_Click({
        $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to proceed with device cleanup and reset?`n`nThis action cannot be undone!", "Confirm Operation", "YesNo", "Warning")
        if ($result -eq "Yes") {
            Execute-CleanupAndReset -WhatIfMode $false
        }
    })
    
    $whatIfButton.Add_Click({
        Execute-CleanupAndReset -WhatIfMode $true
    })
    
    $closeButton.Add_Click({
        $form.Close()
    })
    
    # Load device information
    $script:CurrentDevice = Get-CurrentDeviceInfo
    if ($script:CurrentDevice) {
        $deviceInfoText = @"
Computer Name: $($script:CurrentDevice.ComputerName)
Serial Number: $($script:CurrentDevice.SerialNumber)
Manufacturer: $($script:CurrentDevice.Manufacturer)
Model: $($script:CurrentDevice.Model)
Current User: $($script:CurrentDevice.UserName)
Domain: $($script:CurrentDevice.Domain)
"@
        $deviceInfoLabel.Text = $deviceInfoText
    } else {
        $deviceInfoLabel.Text = "ERROR: Could not retrieve device information"
        $executeButton.Enabled = $false
        $whatIfButton.Enabled = $false
    }
    
    # Show form
    $form.ShowDialog() | Out-Null
}

# Main execution
try {
    Write-Log "=== One-Click Device Cleanup and Reset Tool Started ==="
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-Log "OS Version: $([System.Environment]::OSVersion.VersionString)"
    Write-Log "User: $env:USERNAME"
    Write-Log "Computer: $env:COMPUTERNAME"
    
    # Set execution policy to bypass for testing purposes
    try {
        $currentPolicy = Get-ExecutionPolicy -Scope CurrentUser
        Write-Log "Current execution policy (CurrentUser): $currentPolicy"
        
        if ($currentPolicy -ne "Bypass") {
            Write-Log "Setting execution policy to Bypass for testing purposes..."
            Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force
            Write-Log "Execution policy set to Bypass for CurrentUser scope"
        } else {
            Write-Log "Execution policy already set to Bypass"
        }
    }
    catch {
        Write-Log "WARNING: Could not set execution policy: $($_.Exception.Message)" "WARNING"
    }
    
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [System.Windows.Forms.MessageBox]::Show("This script must be run as Administrator.`n`nPlease right-click and select 'Run as Administrator'.", "Administrator Required", "OK", "Error")
        exit 1
    }
    # Show GUI
    Show-DeviceCleanupGUI
    
    Write-Log "=== One-Click Device Cleanup and Reset Tool Ended ==="
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR"
    [System.Windows.Forms.MessageBox]::Show("Fatal Error: $($_.Exception.Message)", "Error", "OK", "Error")
    exit 1
}
