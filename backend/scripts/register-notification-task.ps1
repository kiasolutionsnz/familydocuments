$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner=Join-Path $root 'scripts\run-notification-watch.ps1'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`""
$trigger=New-ScheduledTaskTrigger -AtStartup
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName 'Kia Family Documents Notifications' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Supervised private Family Documents invitation and reminder notification worker.' -Force | Out-Null
Start-ScheduledTask -TaskName 'Kia Family Documents Notifications'
Write-Host 'Kia Family Documents Notifications scheduled task registered and started.'
