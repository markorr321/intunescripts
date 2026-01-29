<#
.SYNOPSIS
    Backs up Intune Management Extension logs to OneDrive.

.DESCRIPTION
    This script collects the Intune Management Extension logs from the local device,
    compresses them into a ZIP file, and uploads them to the logged-in user's OneDrive.
    The user will be prompted to authenticate with their Microsoft account.

.NOTES
    Author: Intune Admin
    Requires: Microsoft.Graph.Authentication module

.EXAMPLE
    .\Backup-IntuneLogsToOneDrive.ps1

    Collects logs and uploads to the root of OneDrive.

.EXAMPLE
    .\Backup-IntuneLogsToOneDrive.ps1 -OneDriveFolder "IntuneLogs"

    Collects logs and uploads to the "IntuneLogs" folder in OneDrive.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OneDriveFolder = "IntuneLogs"
)

#region Functions

function Write-ColorOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Green", "Red", "Yellow", "Cyan", "White", "Magenta")]
        [string]$Color = "White"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Test-ModuleInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    $module = Get-Module -ListAvailable -Name $ModuleName
    return $null -ne $module
}

function Install-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModuleName
    )

    Write-ColorOutput "Installing $ModuleName module..." "Yellow"

    try {
        Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber
        Write-ColorOutput "Successfully installed $ModuleName" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "Failed to install $ModuleName : $($_.Exception.Message)" "Red"
        return $false
    }
}

function Get-IntuneLogsPath {
    # The Intune Management Extension logs are stored in the local AppData folder
    $logPath = Join-Path -Path $env:ProgramData -ChildPath "Microsoft\IntuneManagementExtension\Logs"

    # Check alternate location in user's AppData
    if (-not (Test-Path -Path $logPath)) {
        $logPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath "Microsoft\IntuneManagementExtension\Logs"
    }

    return $logPath
}

function New-LogsZipFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        # Remove existing zip if it exists
        if (Test-Path -Path $DestinationPath) {
            Remove-Item -Path $DestinationPath -Force
        }

        # Create the zip file
        Compress-Archive -Path "$SourcePath\*" -DestinationPath $DestinationPath -Force

        return $true
    }
    catch {
        Write-ColorOutput "Failed to create ZIP file: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Connect-ToMicrosoftGraph {
    try {
        Write-ColorOutput "Connecting to Microsoft Graph..." "Cyan"
        Write-ColorOutput "A browser window will open for authentication. Please sign in with your Microsoft account." "Yellow"

        # Connect with the required scopes for OneDrive access
        Connect-MgGraph -Scopes @(
            "Files.ReadWrite",
            "User.Read"
        ) -NoWelcome

        # Verify connection
        $context = Get-MgContext
        if ($null -eq $context) {
            throw "Failed to establish Graph connection"
        }

        Write-ColorOutput "Successfully connected as: $($context.Account)" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        return $false
    }
}

function New-OneDriveFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )

    try {
        # Check if folder already exists
        $existingFolder = $null
        try {
            $existingFolder = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/${FolderName}" -Method GET -ErrorAction SilentlyContinue
        }
        catch {
            # Folder doesn't exist, which is fine
        }

        if ($null -ne $existingFolder) {
            Write-ColorOutput "Folder '$FolderName' already exists in OneDrive" "Cyan"
            return $existingFolder.id
        }

        # Create the folder
        $body = @{
            name = $FolderName
            folder = @{}
            "@microsoft.graph.conflictBehavior" = "rename"
        } | ConvertTo-Json

        $folder = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/drive/root/children" -Method POST -Body $body -ContentType "application/json"

        Write-ColorOutput "Created folder '$FolderName' in OneDrive" "Green"
        return $folder.id
    }
    catch {
        Write-ColorOutput "Failed to create OneDrive folder: $($_.Exception.Message)" "Red"
        return $null
    }
}

function Upload-FileToOneDrive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$OneDriveFolderName
    )

    try {
        $fileName = Split-Path -Path $FilePath -Leaf
        $fileSize = (Get-Item -Path $FilePath).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)

        Write-ColorOutput "Uploading '$fileName' ($fileSizeMB MB) to OneDrive..." "Cyan"

        # For files larger than 4MB, use upload session; otherwise use simple upload
        if ($fileSize -gt 4MB) {
            # Create upload session for large files
            $uploadSessionBody = @{
                item = @{
                    "@microsoft.graph.conflictBehavior" = "rename"
                    name = $fileName
                }
            } | ConvertTo-Json

            $uploadSession = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/${OneDriveFolderName}/${fileName}:/createUploadSession" -Method POST -Body $uploadSessionBody -ContentType "application/json"

            $uploadUrl = $uploadSession.uploadUrl

            # Read file content
            $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)

            # Upload in chunks (10MB chunks)
            $chunkSize = 10 * 1024 * 1024
            $chunks = [math]::Ceiling($fileSize / $chunkSize)

            for ($i = 0; $i -lt $chunks; $i++) {
                $start = $i * $chunkSize
                $end = [math]::Min(($i + 1) * $chunkSize - 1, $fileSize - 1)
                $length = $end - $start + 1

                $chunkBytes = $fileBytes[$start..$end]

                $headers = @{
                    "Content-Length" = $length
                    "Content-Range" = "bytes $start-$end/$fileSize"
                }

                $response = Invoke-RestMethod -Uri $uploadUrl -Method PUT -Body $chunkBytes -Headers $headers -ContentType "application/octet-stream"

                $progress = [math]::Round((($i + 1) / $chunks) * 100)
                Write-Progress -Activity "Uploading to OneDrive" -Status "$progress% Complete" -PercentComplete $progress
            }

            Write-Progress -Activity "Uploading to OneDrive" -Completed
        }
        else {
            # Simple upload for small files
            $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)

            $response = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/${OneDriveFolderName}/${fileName}:/content" -Method PUT -Body $fileBytes -ContentType "application/octet-stream"
        }

        Write-ColorOutput "Successfully uploaded '$fileName' to OneDrive" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "Failed to upload file to OneDrive: $($_.Exception.Message)" "Red"
        return $false
    }
}

#endregion Functions

#region Main Script

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Intune Logs Backup to OneDrive" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check and install required modules
Write-ColorOutput "Checking required PowerShell modules..." "Cyan"

$requiredModules = @("Microsoft.Graph.Authentication")

foreach ($module in $requiredModules) {
    if (-not (Test-ModuleInstalled -ModuleName $module)) {
        Write-ColorOutput "Module '$module' is not installed" "Yellow"

        $install = Read-Host "Would you like to install it now? (Y/N)"
        if ($install -eq "Y" -or $install -eq "y") {
            if (-not (Install-RequiredModule -ModuleName $module)) {
                Write-ColorOutput "Cannot proceed without required module. Exiting." "Red"
                exit 1
            }
        }
        else {
            Write-ColorOutput "Cannot proceed without required module. Exiting." "Red"
            exit 1
        }
    }
    else {
        Write-ColorOutput "Module '$module' is installed" "Green"
    }
}

# Import the module
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# Step 2: Locate Intune logs
Write-ColorOutput "Locating Intune Management Extension logs..." "Cyan"

$logsPath = Get-IntuneLogsPath

if (-not (Test-Path -Path $logsPath)) {
    Write-ColorOutput "Intune logs not found at: $logsPath" "Red"
    Write-ColorOutput "Please ensure the Intune Management Extension is installed on this device." "Yellow"
    exit 1
}

$logFiles = Get-ChildItem -Path $logsPath -File -ErrorAction SilentlyContinue
$logCount = ($logFiles | Measure-Object).Count

if ($logCount -eq 0) {
    Write-ColorOutput "No log files found in: $logsPath" "Yellow"
    exit 1
}

Write-ColorOutput "Found $logCount log file(s) at: $logsPath" "Green"

# Step 3: Create ZIP file
Write-ColorOutput "Creating ZIP archive of logs..." "Cyan"

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipFileName = "IntuneLogs-$computerName-$timestamp.zip"
$tempPath = Join-Path -Path $env:TEMP -ChildPath $zipFileName

if (-not (New-LogsZipFile -SourcePath $logsPath -DestinationPath $tempPath)) {
    Write-ColorOutput "Failed to create ZIP file. Exiting." "Red"
    exit 1
}

$zipSize = [math]::Round((Get-Item -Path $tempPath).Length / 1MB, 2)
Write-ColorOutput "Created ZIP file: $zipFileName ($zipSize MB)" "Green"

# Step 4: Connect to Microsoft Graph
if (-not (Connect-ToMicrosoftGraph)) {
    Write-ColorOutput "Failed to connect to Microsoft Graph. Exiting." "Red"

    # Clean up temp file
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Force
    }
    exit 1
}

# Step 5: Create OneDrive folder if needed
$folderId = New-OneDriveFolder -FolderName $OneDriveFolder

if ($null -eq $folderId) {
    Write-ColorOutput "Failed to create/access OneDrive folder. Exiting." "Red"

    # Clean up and disconnect
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Force
    }
    Disconnect-MgGraph | Out-Null
    exit 1
}

# Step 6: Upload ZIP to OneDrive
if (-not (Upload-FileToOneDrive -FilePath $tempPath -OneDriveFolderName $OneDriveFolder)) {
    Write-ColorOutput "Failed to upload file to OneDrive. Exiting." "Red"

    # Clean up and disconnect
    if (Test-Path -Path $tempPath) {
        Remove-Item -Path $tempPath -Force
    }
    Disconnect-MgGraph | Out-Null
    exit 1
}

# Step 7: Clean up
Write-ColorOutput "Cleaning up temporary files..." "Cyan"

if (Test-Path -Path $tempPath) {
    Remove-Item -Path $tempPath -Force
}

# Disconnect from Graph
Disconnect-MgGraph | Out-Null

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Backup Complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-ColorOutput "Your Intune logs have been uploaded to OneDrive" "Green"
Write-ColorOutput "Location: OneDrive > $OneDriveFolder > $zipFileName" "Cyan"
Write-Host ""

#endregion Main Script
