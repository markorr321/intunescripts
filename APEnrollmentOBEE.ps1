##AutPilot Enrollment from OBEE##

Press Shift Function F10 
Type powershell
set-executionpolicy bypass
install-script get-windowsautopilotinfo -force
Get-WindowsAutoPilotInfo.ps1 -GroupTag field -Online 
sysprep\sysprep.exe
test