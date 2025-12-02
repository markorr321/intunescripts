============================================================
AUTOPILOT HARDWARE HASH COLLECTION
============================================================

VERSION: 1.0
FILE: AutoPilotHWID-Collection.bat
REQUIREMENTS: Internet connection, USB drive with script


============================================================
METHOD 1: DIRECT CMD (Use this if Shift+F10 works normally)
============================================================

STEPS:
1. During Windows setup (OOBE), press: Shift + F10
   - A black command prompt window opens

2. Type: d:
   - Press: Enter
   - (Changes to D: drive - your USB drive)

3. Type: Auto
   - Press: Tab (autocompletes to AutoPilotHWID-Collection.bat)
   - Press: Enter

4. Click "Yes" when UAC prompt appears

5. Wait for completion (1-2 minutes)

6. Press Enter to close

7. Remove USB drive - files saved to USB!


============================================================
METHOD 2: USING RUN DIALOG (Use if keyboard doesn't work in CMD)
============================================================

STEPS:
1. During Windows setup (OOBE), press: Shift + F10
   - A black command prompt window opens (keyboard may not work)

2. Press: Windows + R
   - Run dialog opens (keyboard should work here!)

3. Type: cmd
   - Press: Enter
   - A new CMD window opens

4. Type: d:
   - Press: Enter
   - (Changes to D: drive - your USB drive)

5. Type: Auto
   - Press: Tab (autocompletes to AutoPilotHWID-Collection.bat)
   - Press: Enter

6. Click "Yes" when UAC prompt appears

7. Wait for completion (1-2 minutes)

8. Press Enter to close

9. Remove USB drive - files saved to USB!


============================================================
METHOD 3: EXPLORER (Mouse-only method)
============================================================

STEPS:
1. Press: Shift + F10
   - CMD window opens

2. Type: explorer
   - Press: Enter
   - (File Explorer opens)

3. Navigate to D: drive (or your USB drive letter)

4. Double-click: AutoPilotHWID-Collection.bat

5. Click "Yes" when UAC prompt appears

6. Wait for completion

7. Press Enter to close

8. Remove USB drive


============================================================
OUTPUT FILES
============================================================

LOCAL COPY:
  Location: C:\HWID\
  Filename: AutoPilotHWID_[SerialNumber].csv
  
USB BACKUP:
  Location: D:\AutoPilot_[SerialNumber]\
  Filename: AutoPilotHWID_[SerialNumber].csv

Example:
  D:\AutoPilot_MZ00EERC\AutoPilotHWID_MZ00EERC.csv


============================================================
TROUBLESHOOTING
============================================================

ISSUE: Keyboard doesn't work in CMD window
  FIX: Use METHOD 2 (Windows + R to open Run dialog)

ISSUE: D: drive not found
  FIX: Your USB might be a different letter (E:, F:, etc.)
       Use "explorer" command to check drive letter

ISSUE: Script fails with errors
  FIX: Ensure device has internet connection
       Windows needs to download collection tools

ISSUE: UAC prompt doesn't appear
  FIX: Right-click AutoPilotHWID-Collection.bat
       Select "Run as administrator"

ISSUE: No CSV file created
  FIX: Check C:\HWID\ for error logs
       Verify internet connection
       Ensure USB drive is not write-protected


============================================================
WHAT THE SCRIPT DOES
============================================================

1. Creates workspace: C:\HWID\
2. Gets device serial number from BIOS
3. Installs NuGet provider (PowerShell Gallery requirement)
4. Downloads Get-WindowsAutopilotInfo script
5. Collects hardware hash (HWID)
6. Saves CSV file with serial number in filename
7. Backs up to USB drive automatically
8. Opens folder when complete


============================================================
NEXT STEPS AFTER COLLECTION
============================================================

1. Remove USB drive from device

2. Upload CSV file to Microsoft Intune:
   - Sign in to: https://intune.microsoft.com
   - Go to: Devices > Enroll devices > Windows enrollment
   - Select: Windows Autopilot Deployment Program
   - Click: Import
   - Select your CSV file(s)
   - Wait for processing (5-15 minutes)

3. Assign Autopilot profile to imported devices

4. Device is ready for Autopilot deployment!


============================================================
KEYBOARD SHORTCUTS REFERENCE
============================================================

Shift + F10         = Open CMD in Windows setup
Windows + R         = Open Run dialog
Tab                 = Autocomplete filename
Ctrl + C            = Cancel current command
Exit                = Close CMD window
