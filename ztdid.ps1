#How to get the ZTDID of a single device.

Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All | Where-Object { $_.SerialNumber -eq '5C5PT94' } | Select-Object Id, SerialNumber, GroupTag

