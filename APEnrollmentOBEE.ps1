##AutPilot Enrollment from OBEE##

#Launch a command line
Press Shift F10 
Close the command line

#Launch a Powershell Admin Window
Windows R --> Type: Powershell --> Press Control Shift Enter

#Set Executionpolicy
set-executionpolicy bypass

#Installs "Get-WindowsAutoPilotInfo Script
install-script get-windowsautopilotinfo -force

# Runs the Get-WindowsAutoPilotInfo script to gather device information for Windows AutoPilot and upload it to the Microsoft Endpoint Manager admin center (Intune)
Get-WindowsAutoPilotInfo.ps1 -GroupTag field -Online 

#Prepares the Windows installation for imaging or deployment
sysprep\sysprep.exe
