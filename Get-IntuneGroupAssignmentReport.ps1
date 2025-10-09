<#
.SYNOPSIS
  Intune Assignment Reporter - Comprehensive analysis of Microsoft Intune assignments for device groups

.DESCRIPTION
  This PowerShell script provides a comprehensive analysis of all Microsoft Intune assignments 
  targeting a specific Entra ID device group. It generates detailed reports showing which policies, 
  applications, and configurations are assigned to the selected group.

  Features:
  - Interactive group selection with search functionality
  - Comprehensive policy coverage including:
    * Configuration Profiles
    * Settings Catalog Policies  
    * Compliance Policies
    * Applications (with Required/Available/Uninstall intent)
    * Endpoint Security Policies
    * PowerShell Scripts
    * Proactive Remediations
    * Enrollment Status Page (ESP) Profiles
    * Windows Autopilot Deployment Profiles
  - Multiple output formats:
    * Enhanced terminal display with color coding
    * Excel export with multiple worksheets
    * Interactive Out-GridView for filtering and sorting
  - Custom sorting and organization of results
  - Platform translation for user-friendly display
  - Assignment intent reporting for applications

.AUTHOR
  Mark Orr

.PUBLISHED
  October 09, 2025

.NOTES
  Required PowerShell Modules:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.DeviceManagement
    - Microsoft.Graph.Groups
    - Microsoft.Graph.Applications
    - ImportExcel (for Excel export functionality)

  Requires Graph scopes:
    - DeviceManagementConfiguration.Read.All
    - DeviceManagementApps.Read.All
    - DeviceManagementManagedDevices.Read.All
    - Directory.Read.All

.EXAMPLE
  .\Get-IntuneAssignmentsForDeviceGroup-Fixed.ps1
  
  Runs the script interactively, prompting for group selection and generating comprehensive reports.
#>

[CmdletBinding()]
param()

#---------------------------- Helper: Connect Graph ----------------------------#
function Ensure-GraphConnection {
  $needed = @(
    "DeviceManagementConfiguration.Read.All",
    "DeviceManagementApps.Read.All", 
    "DeviceManagementManagedDevices.Read.All",
    "Directory.Read.All"
  )
  try {
    if (-not (Get-MgContext)) {
      Connect-MgGraph -Scopes $needed -NoWelcome
    }
  } catch {
    throw "Connect-MgGraph failed: $($_.Exception.Message)"
  }
}
Ensure-GraphConnection

# Display connection information
try {
  $context = Get-MgContext
  if ($context) {
    Write-Host ""
    Write-Host "MICROSOFT GRAPH CONNECTION INFO" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Tenant ID: " -NoNewline -ForegroundColor White
    Write-Host "$($context.TenantId)" -ForegroundColor Cyan
    Write-Host "Account: " -NoNewline -ForegroundColor White
    Write-Host "$($context.Account)" -ForegroundColor Green
    Write-Host ""
  }
} catch {
  Write-Verbose "Could not retrieve Graph context information"
}

#---------------------------- Interactive Group Selection ----------------------------#
Write-Host "INTUNE ASSIGNMENT REPORTER" -ForegroundColor Yellow
Write-Host ""
Write-Host "Author: " -NoNewline -ForegroundColor White
Write-Host "Mark Orr" -ForegroundColor Green
Write-Host "Date: " -NoNewline -ForegroundColor White
Write-Host "10/09/2025" -ForegroundColor Green
Write-Host ""

# Prompt for group name
do {
  $GroupName = Read-Host "Enter the Entra ID group name to analyze"
  if ([string]::IsNullOrWhiteSpace($GroupName)) {
    Write-Host "Group name cannot be empty. Please try again." -ForegroundColor Red
  }
} while ([string]::IsNullOrWhiteSpace($GroupName))

#---------------------------- Resolve Group ----------------------------#
Write-Host "🔍 " -NoNewline -ForegroundColor Yellow
Write-Host "Searching for group: " -NoNewline -ForegroundColor Gray
Write-Host "'$GroupName'" -ForegroundColor White
Write-Host ""

try {
  $group = Get-MgGroup -Filter "displayName eq '$($GroupName.Replace("'","''"))'"
  if (-not $group) { 
    Write-Host "❌ " -NoNewline -ForegroundColor Red
    Write-Host "Group '$GroupName' not found. Please check the name and try again." -ForegroundColor Red
    exit 1
  }
  if ($group.Count -gt 1) { 
    Write-Host "⚠️  " -NoNewline -ForegroundColor Yellow
    Write-Host "Multiple groups found with name '$GroupName':" -ForegroundColor Yellow
    $group | ForEach-Object { Write-Host "  - $($_.DisplayName) ($($_.Id))" -ForegroundColor White }
    Write-Host "Please use a more specific group name." -ForegroundColor Red
    exit 1
  }
  $resolvedGroupId = $group.Id
  $resolvedGroupName = $group.DisplayName
} catch {
  Write-Host "❌ " -NoNewline -ForegroundColor Red
  Write-Host "Failed to resolve group: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host "✅ " -NoNewline -ForegroundColor Green
Write-Host "Target Group: " -NoNewline -ForegroundColor Gray
Write-Host "$resolvedGroupName " -NoNewline -ForegroundColor Cyan
Write-Host "($resolvedGroupId)" -ForegroundColor DarkGray
Write-Host ""

#---------------------------- Helpers: Normalization ----------------------------#
function Resolve-AssignmentMeta {
  param(
    [hashtable]$AssignmentHash,
    [string]$PolicyType
  )
  $targetType = $AssignmentHash.target.'@odata.type'
  $groupIdInTarget = $AssignmentHash.target.groupId
  $filterId  = $AssignmentHash.target.deviceAndAppManagementAssignmentFilterId
  $filterTyp = $AssignmentHash.target.deviceAndAppManagementAssignmentFilterType
  $intent = $AssignmentHash.intent

  $assignmentStyle = switch ($targetType) {
    "#microsoft.graph.groupAssignmentTarget"               { "Include" }
    "#microsoft.graph.exclusionGroupAssignmentTarget"      { "Exclude" }
    "#microsoft.graph.allDevicesAssignmentTarget"          { "All Devices" }
    "#microsoft.graph.allLicensedUsersAssignmentTarget"    { "All Users" }
    default                                                { ($targetType -replace '^#microsoft\.graph\.', '') }
  }

  # For Applications, get the intent (Required, Available, Uninstall)
  $appIntent = ""
  if ($PolicyType -eq "Applications" -and $intent) {
    $appIntent = switch ($intent) {
      "required" { "Required" }
      "available" { "Available" }
      "uninstall" { "Uninstall" }
      default { $intent }
    }
  }

  # match is true if this specific assignment targets our group (include or exclude)
  $isMatch = $false
  if ($groupIdInTarget -and ($groupIdInTarget -eq $resolvedGroupId)) {
    $isMatch = $true
  }

  [pscustomobject]@{
    PolicyType   = $PolicyType
    Assignment   = $assignmentStyle
    TargetType   = $targetType
    TargetGroupId= $groupIdInTarget
    FilterType   = $filterTyp
    FilterId     = $filterId
    AppIntent    = $appIntent
    IsMatch      = $isMatch
  }
}

function New-ResultRow {
  param(
    [string]$PolicyType,
    [string]$DisplayName,
    [string]$ObjectId,
    [string]$Platform,
    [pscustomobject]$Meta
  )
  
  # Translate platform types
  if ($PolicyType -eq "Applications") {
    $Platform = switch ($Platform) {
      "#microsoft.graph.win32LobApp" { "Win32" }
      "#microsoft.graph.windowsMicrosoftEdgeApp" { "Windows 10 and Later" }
      default { $Platform }
    }
  }
  elseif ($PolicyType -eq "Compliance Policies") {
    $Platform = switch ($Platform) {
      "#microsoft.graph.windows10CompliancePolicy" { "Windows Compliance Policy" }
      default { $Platform }
    }
  }
  
  [pscustomobject]@{
    Type            = $PolicyType
    Name            = $DisplayName
    PolicyId        = $ObjectId
    Platform        = $Platform
    Assignment      = $Meta.Assignment
    AppIntent       = $Meta.AppIntent
    TargetGroupId   = $Meta.TargetGroupId
    FilterType      = $Meta.FilterType
    FilterId        = $Meta.FilterId
    PathHint        = switch ($PolicyType) {
      "Configuration Profiles" { "Devices > Configuration profiles" }
      "Settings Catalogs"      { "Devices > Configuration profiles (Settings catalog)" }
      "Compliance Policies"    { "Devices > Compliance policies" }
      "Endpoint Security"      { "Endpoint security > Policies" }
      "PowerShell Script"      { "Devices > Scripts" }
      "Remediation"            { "Devices > Remediations" }
      "Applications"           { "Apps > All apps" }
      "ESP"                    { "Devices > Enrollment Status Page" }
      "Deployment Profile"     { "Devices > Deployment profiles" }
      default                  { "" }
    }
    GroupMatched    = $Meta.IsMatch
  }
}

#---------------------------- Helper Function for Graph API Assignments ----------------------------#
function Get-AssignedItems {
    param(
        [string]$url,
        [string]$type,
        [string]$nameField = "displayName"
    )

    $results = @()
    try {
        $items = Invoke-MgGraphRequest -Uri $url -Method GET

        foreach ($item in $items.value) {
            if ($item.assignments) {
                foreach ($assignment in $item.assignments) {
                    if($assignment.target.groupId -eq $resolvedGroupId) {
                        $results += [PSCustomObject]@{
                            Type = $type
                            Name = $item.$nameField
                            Id = $item.id
                            Assignment = $assignment
                        }
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to get $type : $($_.Exception.Message)"
    }

    return $results
}

#---------------------------- Collectors per workload ----------------------------#
$results = New-Object System.Collections.Generic.List[object]

Write-Host "📊 " -NoNewline -ForegroundColor Blue
Write-Host "Collecting assignments..." -ForegroundColor Gray

# Device Configuration Profiles - Enhanced with Graph API
try {
  # Use the helper function for Configuration Profiles
  $configProfiles = Get-AssignedItems -url "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?`$expand=assignments" -type "Configuration Profile"
  
  foreach ($item in $configProfiles) {
    $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $item.Assignment.target} -PolicyType "Configuration Profiles"
    if ($meta.IsMatch) {
      $results.Add((New-ResultRow -PolicyType "Configuration Profiles" -DisplayName $item.Name -ObjectId $item.Id -Platform "Device Configuration" -Meta $meta)) | Out-Null
    }
  }
  
  # Also get traditional Configuration Profiles using cmdlets as fallback
  Get-MgDeviceManagementDeviceConfiguration -All -ExpandProperty Assignments | ForEach-Object {
    $policy = $_
    foreach ($as in $policy.Assignments) {
      $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target} -PolicyType "Configuration Profiles"
      if ($meta.IsMatch) {
        # Check if we already have this policy from the Graph API call
        $existing = $results | Where-Object { $_.PolicyId -eq $policy.Id -and $_.Type -eq "Configuration Profiles" }
        if (-not $existing) {
          $results.Add((New-ResultRow -PolicyType "Configuration Profiles" -DisplayName $policy.DisplayName -ObjectId $policy.Id -Platform $policy.'@odata.type' -Meta $meta)) | Out-Null
        }
      }
    }
  }
} catch {
  Write-Warning "Failed to get Configuration Profiles: $($_.Exception.Message)"
}

# Compliance Policies - Using Graph API directly
try {
  $compliancePolicies = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies?`$expand=assignments" -Method GET
  foreach ($policy in $compliancePolicies.value) {
    if ($policy.assignments) {
      foreach ($as in $policy.assignments) {
        $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target} -PolicyType "Compliance Policies"
        if ($meta.IsMatch) {
          $results.Add((New-ResultRow -PolicyType "Compliance Policies" -DisplayName $policy.displayName -ObjectId $policy.id -Platform $policy.'@odata.type' -Meta $meta)) | Out-Null
        }
      }
    }
  }
} catch {
  Write-Warning "Failed to get Compliance Policies: $($_.Exception.Message)"
}

# PowerShell Scripts - Using beta endpoint
try {
  $scripts = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts" -Method GET
  foreach ($script in $scripts.value) {
    # Get assignments separately for each script using beta
    try {
      $assignments = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$($script.id)/assignments" -Method GET
      foreach ($as in $assignments.value) {
        $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target} -PolicyType "PowerShell Script"
        if ($meta.IsMatch) {
          $results.Add((New-ResultRow -PolicyType "PowerShell Script" -DisplayName $script.displayName -ObjectId $script.id -Platform $script.runAsAccount -Meta $meta)) | Out-Null
        }
      }
    } catch {
      # Skip this script if assignments can't be retrieved
      Write-Verbose "Could not get assignments for script: $($script.displayName)"
    }
  }
} catch {
  # Silently skip PowerShell Scripts if the endpoint is not available
  Write-Verbose "PowerShell Scripts endpoint not accessible, skipping..."
}

# Apps - Using Graph API directly
try {
  $apps = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$expand=assignments" -Method GET
  foreach ($app in $apps.value) {
    if ($app.assignments) {
      foreach ($as in $app.assignments) {
        $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target; intent = $as.intent} -PolicyType "Applications"
        if ($meta.IsMatch) {
          $results.Add((New-ResultRow -PolicyType "Applications" -DisplayName $app.displayName -ObjectId $app.id -Platform $app.'@odata.type' -Meta $meta)) | Out-Null
        }
      }
    }
  }
} catch {
  Write-Warning "Failed to get Apps: $($_.Exception.Message)"
}

# Settings Catalog Policies - Using Graph API directly
try {
  $settingsPolicies = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$expand=assignments" -Method GET
  foreach ($policy in $settingsPolicies.value) {
    if ($policy.assignments) {
      foreach ($as in $policy.assignments) {
        $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target} -PolicyType "Settings Catalogs"
        if ($meta.IsMatch) {
          $results.Add((New-ResultRow -PolicyType "Settings Catalogs" -DisplayName $policy.name -ObjectId $policy.id -Platform $policy.platforms -Meta $meta)) | Out-Null
        }
      }
    }
  }
} catch {
  Write-Warning "Failed to get Settings Catalog Policies: $($_.Exception.Message)"
}

# Endpoint Security Policies - Using Graph API directly
try {
  $endpointPolicies = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceManagement/intents?`$expand=assignments" -Method GET
  foreach ($policy in $endpointPolicies.value) {
    if ($policy.assignments) {
      foreach ($as in $policy.assignments) {
        $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $as.target} -PolicyType "Endpoint Security"
        if ($meta.IsMatch) {
          $results.Add((New-ResultRow -PolicyType "Endpoint Security" -DisplayName $policy.displayName -ObjectId $policy.id -Platform $policy.templateId -Meta $meta)) | Out-Null
        }
      }
    }
  }
} catch {
  Write-Warning "Failed to get Endpoint Security Policies: $($_.Exception.Message)"
}

# Enrollment Status Page (ESP) Profiles
try {
  $espProfiles = Get-AssignedItems -url "https://graph.microsoft.com/beta/deviceManagement/deviceEnrollmentConfigurations?`$expand=assignments" -type "ESP"
  
  foreach ($item in $espProfiles) {
    $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $item.Assignment.target} -PolicyType "ESP"
    if ($meta.IsMatch) {
      $results.Add((New-ResultRow -PolicyType "ESP" -DisplayName $item.Name -ObjectId $item.Id -Platform "Windows" -Meta $meta)) | Out-Null
    }
  }
} catch {
  Write-Warning "Failed to get ESP Profiles: $($_.Exception.Message)"
}

# Windows Autopilot Deployment Profiles
try {
  $deploymentProfiles = Get-AssignedItems -url "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles?`$expand=assignments" -type "Deployment Profile"
  
  foreach ($item in $deploymentProfiles) {
    $meta = Resolve-AssignmentMeta -AssignmentHash @{target = $item.Assignment.target} -PolicyType "Deployment Profile"
    if ($meta.IsMatch) {
      $results.Add((New-ResultRow -PolicyType "Deployment Profile" -DisplayName $item.Name -ObjectId $item.Id -Platform "Windows Autopilot" -Meta $meta)) | Out-Null
    }
  }
} catch {
  Write-Warning "Failed to get Deployment Profiles: $($_.Exception.Message)"
}

#---------------------------- Output Results ----------------------------#

# Define custom sort order
$sortOrder = @(
  "Deployment Profile",
  "ESP", 
  "Applications",
  "Configuration Profiles",
  "Settings Catalogs",
  "Compliance Policies",
  "Endpoint Security",
  "PowerShell Script",
  "Remediation"
)

# User Choice for Output Format
Write-Host ""
Write-Host "INTUNE ASSIGNMENTS REPORT RESULTS" -ForegroundColor Yellow
Write-Host ""
Write-Host "Group: " -NoNewline -ForegroundColor White
Write-Host "$resolvedGroupName" -ForegroundColor Cyan
Write-Host "Generated: " -NoNewline -ForegroundColor White
Write-Host "$(Get-Date -Format 'MMMM dd, yyyy at hh:mm:ss tt')" -ForegroundColor Gray
Write-Host "Total Assignments: " -NoNewline -ForegroundColor White
Write-Host "$($results.Count)" -ForegroundColor Yellow
Write-Host ""

if ($results.Count -eq 0) {
  Write-Host "No assignments found targeting this group." -ForegroundColor Yellow
} else {
  # Group by policy type and sort by custom order
  $groupedResults = $results | Group-Object Type | Sort-Object { 
    $index = $sortOrder.IndexOf($_.Name)
    if ($index -eq -1) { 999 } else { $index }
  }
  
  # User choice for output format
  Write-Host "📋 " -NoNewline -ForegroundColor Blue
  Write-Host "Choose output format:" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "1. Terminal Display" -ForegroundColor White
  Write-Host "2. Interactive Grid View (OGV)" -ForegroundColor White
  Write-Host "3. Excel Export (CSV)" -ForegroundColor White
  Write-Host ""
  
  do {
    $choice = Read-Host "Enter your choice (1-3)"
  } while ($choice -notin @("1","2","3"))
  
  switch ($choice) {
    "1" {
      # Terminal Output
      Write-Host ""
      foreach ($group in $groupedResults) {
        Write-Host "[$($group.Name)] - $($group.Count) assignment(s)" -ForegroundColor Magenta
        Write-Host ("-" * 50) -ForegroundColor Gray
        
        $group.Group | ForEach-Object {
          Write-Host "  • " -NoNewline -ForegroundColor White
          Write-Host "$($_.Name)" -ForegroundColor White
          Write-Host "    Assignment: " -NoNewline -ForegroundColor Gray
          Write-Host "$($_.Assignment)" -ForegroundColor $(if($_.Assignment -eq "Include") {"Green"} elseif($_.Assignment -eq "Exclude") {"Red"} else {"Yellow"})
          if ($_.Type -eq "Applications" -and $_.AppIntent -and $_.AppIntent -ne "") {
            Write-Host "    Intent: " -NoNewline -ForegroundColor Gray
            Write-Host "$($_.AppIntent)" -ForegroundColor $(if($_.AppIntent -eq "Required") {"Red"} elseif($_.AppIntent -eq "Available") {"Green"} elseif($_.AppIntent -eq "Uninstall") {"Yellow"} else {"White"})
          }
          Write-Host "    Platform: $($_.Platform)" -ForegroundColor Gray
          Write-Host ""
        }
      }
    }
    "2" {
      # Out-GridView
      Write-Host "Opening interactive grid view..." -ForegroundColor Cyan
      $sortedResults = $results | Sort-Object { 
        $index = $sortOrder.IndexOf($_.Type)
        if ($index -eq -1) { 999 } else { $index }
      }, Name
      $sortedResults | Out-GridView -Title "Intune Assignments for Group: $resolvedGroupName" -PassThru
    }
    "3" {
      # Excel Export
      $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
      $excelPath = "IntuneAssignments-$($resolvedGroupName.Replace(' ','_'))-$timestamp.xlsx"
      
      # Install ImportExcel module if not present
      if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Host "Installing ImportExcel module for multi-sheet export..." -ForegroundColor Yellow
        Install-Module ImportExcel -Scope CurrentUser -Force
      }
      
      Import-Module ImportExcel
      
      # Summary sheet
      $summaryData = $groupedResults | ForEach-Object {
        [PSCustomObject]@{
          PolicyType = $_.Name
          Count = $_.Count
        }
      }
      
      $summaryData | Export-Excel -Path $excelPath -WorksheetName "Summary" -AutoSize -FreezeTopRow -BoldTopRow
      
      # Individual sheets per policy type
      foreach ($group in $groupedResults) {
        $sheetName = $group.Name -replace '[^\w]', '_'
        $group.Group | Select-Object Type, Name, PolicyId, Platform, Assignment, AppIntent, TargetGroupId, FilterType, FilterId | Export-Excel -Path $excelPath -WorksheetName $sheetName -AutoSize -FreezeTopRow -BoldTopRow
      }
      
      # All assignments sheet
      $results | Select-Object Type, Name, PolicyId, Platform, Assignment, AppIntent, TargetGroupId, FilterType, FilterId | Export-Excel -Path $excelPath -WorksheetName "All_Assignments" -AutoSize -FreezeTopRow -BoldTopRow
      
      Write-Host "Excel report exported to: $excelPath" -ForegroundColor Green
    }
  }
}

Write-Host "`nReport completed successfully!" -ForegroundColor Green
