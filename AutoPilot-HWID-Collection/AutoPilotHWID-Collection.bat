@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM Check for administrator privileges and auto-elevate if needed
REM ============================================================================

REM Check if running as administrator
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :RunScript
)

REM If not admin, re-launch with elevation
echo Requesting administrator privileges...
echo.
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:RunScript
cls
echo.
echo ============================================================================
echo  AutoPilot Hardware Hash Collection
echo  Administrator Mode
echo ============================================================================
echo.
echo Initializing...
echo.

REM Create PowerShell script line by line
set "PSSCRIPT=%TEMP%\collect_autopilot.ps1"

REM Clear any existing script
if exist "%PSSCRIPT%" del "%PSSCRIPT%"

REM Build the PowerShell script
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo Write-Host "Step 1: Creating workspace..." -ForegroundColor Cyan >> "%PSSCRIPT%"
echo New-Item -Type Directory -Path "C:\HWID" -Force ^| Out-Null >> "%PSSCRIPT%"
echo Write-Host "  Workspace ready" -ForegroundColor Green >> "%PSSCRIPT%"
echo Set-Location "C:\HWID" >> "%PSSCRIPT%"
echo $env:Path += ";C:\Program Files\WindowsPowerShell\Scripts" >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo $serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber >> "%PSSCRIPT%"
echo $outputFile = "C:\HWID\AutoPilotHWID_$serialNumber.csv" >> "%PSSCRIPT%"
echo Write-Host "Device Serial: $serialNumber" -ForegroundColor Cyan >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo Write-Host "Step 2: Installing collection tools..." -ForegroundColor Cyan >> "%PSSCRIPT%"
echo Write-Host "  Installing NuGet provider..." -ForegroundColor Yellow >> "%PSSCRIPT%"
echo Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force ^| Out-Null >> "%PSSCRIPT%"
echo Write-Host "  Installing Get-WindowsAutopilotInfo..." -ForegroundColor Yellow >> "%PSSCRIPT%"
echo Install-Script -Name Get-WindowsAutopilotInfo -Scope AllUsers -Force -Confirm:$false -WarningAction SilentlyContinue ^| Out-Null >> "%PSSCRIPT%"
echo Write-Host "  Tools installed" -ForegroundColor Green >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo Write-Host "Step 3: Collecting hardware hash..." -ForegroundColor Cyan >> "%PSSCRIPT%"
echo Write-Host "  Please wait..." -ForegroundColor Yellow >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo Get-WindowsAutopilotInfo.ps1 -OutputFile $outputFile -WarningAction SilentlyContinue 2^>^&1 ^| Out-Null >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo Write-Host "============================================================================" -ForegroundColor Green >> "%PSSCRIPT%"
echo Write-Host " Hardware Hash Collection Complete" -ForegroundColor Green >> "%PSSCRIPT%"
echo Write-Host "============================================================================" -ForegroundColor Green >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"
echo if (Test-Path $outputFile) { >> "%PSSCRIPT%"
echo     $file = Get-Item $outputFile >> "%PSSCRIPT%"
echo     Write-Host "Location: $($file.FullName)" -ForegroundColor Cyan >> "%PSSCRIPT%"
echo     Write-Host "Size:     $($file.Length) bytes" -ForegroundColor Cyan >> "%PSSCRIPT%"
echo     Write-Host "" >> "%PSSCRIPT%"
echo     if (Test-Path "D:\") { >> "%PSSCRIPT%"
echo         Write-Host "Backing up to USB drive..." -ForegroundColor Cyan >> "%PSSCRIPT%"
echo         $usbFolder = "D:\AutoPilot_$serialNumber" >> "%PSSCRIPT%"
echo         New-Item -Path $usbFolder -ItemType Directory -Force ^| Out-Null >> "%PSSCRIPT%"
echo         Copy-Item -Path $outputFile -Destination $usbFolder -Force >> "%PSSCRIPT%"
echo         Write-Host "  USB: $usbFolder\AutoPilotHWID_$serialNumber.csv" -ForegroundColor Green >> "%PSSCRIPT%"
echo     } else { >> "%PSSCRIPT%"
echo         Write-Host "USB drive not detected - file saved to C:\HWID only" -ForegroundColor Yellow >> "%PSSCRIPT%"
echo     } >> "%PSSCRIPT%"
echo } >> "%PSSCRIPT%"
echo Write-Host "" >> "%PSSCRIPT%"

REM Run PowerShell script
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%PSSCRIPT%"

REM Check results
if exist "C:\HWID\AutoPilotHWID_*.csv" (
    echo ============================================================================
    echo  Collection Complete
    echo ============================================================================
    echo.
    REM Open USB folder if it exists, otherwise open C:\HWID
    if exist "D:\AutoPilot_*" (
        echo Opening USB folder...
        for /d %%i in ("D:\AutoPilot_*") do start explorer "%%i"
    ) else (
        echo Opening C:\HWID folder...
        start explorer "C:\HWID"
    )
) else (
    echo.
    echo ============================================================================
    echo  ERROR - Collection Failed
    echo ============================================================================
    echo.
    echo CSV file was not created. Please check the errors above.
)

echo.
echo.
set /p "=Press Enter to exit..."

REM Cleanup
if exist "%PSSCRIPT%" del "%PSSCRIPT%"
