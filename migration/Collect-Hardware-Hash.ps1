#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Collect Hardware Hash and Upload to Azure Storage Blob for Intune Post-Remediation

.DESCRIPTION
    This script collects the hardware hash using Get-WindowsAutopilotInfo and uploads
    the resulting CSV file to an Azure Storage blob container. Designed for use as
    a post-remediation script in Microsoft Intune.

.PARAMETER StorageAccountName
    The name of the Azure Storage Account

.PARAMETER ContainerName
    The name of the blob container (default: "hardware-hashes")

.PARAMETER SasToken
    The SAS token for accessing the Azure Storage blob (should include leading ?)

.EXAMPLE
    .\Collect-Hardware-Hash.ps1 -StorageAccountName "mystorageaccount" -SasToken "?sv=2021-06-08&ss=b..."
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $false)]
    [string]$ContainerName = "hardware-hashes",
    
    [Parameter(Mandatory = $true)]
    [string]$SasToken
)

# Function to write log entries
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
    
    # Also write to event log for Intune visibility
    try {
        Write-EventLog -LogName "Application" -Source "Hardware Hash Collection" -EventId 1001 -EntryType Information -Message $Message -ErrorAction SilentlyContinue
    }
    catch {
        # Event source might not exist, ignore error
    }
}

# Function to upload file to Azure Storage blob
function Upload-ToAzureBlob {
    param(
        [string]$FilePath,
        [string]$StorageAccountName,
        [string]$ContainerName,
        [string]$SasToken,
        [string]$BlobName
    )
    
    try {
        # Construct the blob URL
        $blobUrl = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName$SasToken"
        
        # Read file content
        $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
        
        # Create HTTP request
        $headers = @{
            'x-ms-blob-type' = 'BlockBlob'
            'Content-Type' = 'text/csv'
        }
        
        # Upload file
        Write-Log "Uploading file to Azure Storage: $BlobName"
        $response = Invoke-RestMethod -Uri $blobUrl -Method Put -Body $fileBytes -Headers $headers
        
        Write-Log "Successfully uploaded $BlobName to Azure Storage"
        return $true
    }
    catch {
        Write-Log "Failed to upload to Azure Storage: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Main script execution
try {
    Write-Log "Starting Hardware Hash collection process"
    
    # Set TLS 1.2 for secure connections
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Create working directory
    $workingDir = "C:\HWID"
    if (-not (Test-Path $workingDir)) {
        New-Item -Type Directory -Path $workingDir -Force | Out-Null
        Write-Log "Created working directory: $workingDir"
    }
    
    Set-Location -Path $workingDir
    
    # Set execution policy for current process
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
    Write-Log "Set execution policy to RemoteSigned for current process"
    
    # Check if Get-WindowsAutopilotInfo is already installed
    $autopilotScript = Get-InstalledScript -Name "Get-WindowsAutopilotInfo" -ErrorAction SilentlyContinue
    
    if (-not $autopilotScript) {
        Write-Log "Installing Get-WindowsAutopilotInfo script"
        # Add PowerShell Scripts path to environment
        $env:Path += ";C:\Program Files\WindowsPowerShell\Scripts"
        
        # Install the script
        Install-Script -Name Get-WindowsAutopilotInfo -Force -Scope CurrentUser
        Write-Log "Successfully installed Get-WindowsAutopilotInfo"
    } else {
        Write-Log "Get-WindowsAutopilotInfo already installed, version: $($autopilotScript.Version)"
    }
    
    # Generate unique filename with computer name and timestamp
    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $csvFileName = "AutopilotHWID-$computerName-$timestamp.csv"
    $csvFilePath = Join-Path $workingDir $csvFileName
    
    # Collect hardware hash
    Write-Log "Collecting hardware hash for computer: $computerName"
    Get-WindowsAutopilotInfo -OutputFile $csvFilePath
    
    # Verify CSV file was created
    if (Test-Path $csvFilePath) {
        $fileSize = (Get-Item $csvFilePath).Length
        Write-Log "Hardware hash CSV created successfully: $csvFileName (Size: $fileSize bytes)"
        
        # Upload to Azure Storage
        $uploadSuccess = Upload-ToAzureBlob -FilePath $csvFilePath -StorageAccountName $StorageAccountName -ContainerName $ContainerName -SasToken $SasToken -BlobName $csvFileName
        
        if ($uploadSuccess) {
            Write-Log "Hardware hash collection and upload completed successfully"
            
            # Clean up local file after successful upload
            Remove-Item $csvFilePath -Force
            Write-Log "Cleaned up local CSV file"
            
            # Exit with success code
            exit 0
        } else {
            Write-Log "Upload failed, keeping local file: $csvFilePath" -Level "ERROR"
            exit 1
        }
    } else {
        Write-Log "Failed to create hardware hash CSV file" -Level "ERROR"
        exit 1
    }
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
    exit 1
}
finally {
    # Return to original location
    Set-Location -Path $env:USERPROFILE
    Write-Log "Hardware hash collection script completed"
}