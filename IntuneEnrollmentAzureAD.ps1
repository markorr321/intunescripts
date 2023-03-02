At the OOBE, open a command prompt session. Shift F10 

# Launch PowerShell
Powershell.exe

# Set PowerShell Execution Policy
Set-ExecutionPolicy bypass

# Install the AutoPilot Script
install-script get-windowsautopilotinfo

# Run the Get Windows AutoPilot Info Command
Get-WindowsAutoPilotInfo.ps1 -online

#Example Script
Get-WindowsAutoPilotInfo.ps1 -GroupTag field -Online -Assign -AssignedUser mark.orr@qcholdings.com -AssignedComputerName 101-01

# Login with Azure AD credentials when prompted