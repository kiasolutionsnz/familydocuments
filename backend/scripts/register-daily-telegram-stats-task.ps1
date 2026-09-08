$ErrorActionPreference='Stop'
$taskName='Kia Family Documents Daily Stats'
$runner=Join-Path $PSScriptRoot 'send-daily-telegram-stats.ps1'
if(-not(Test-Path -LiteralPath $runner)){throw "Daily statistics runner not found: $runner"}
$powerShell=(Get-Command powershell.exe -ErrorAction Stop).Source
$action=New-ScheduledTaskAction -Execute $powerShell -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runner`""
$trigger=New-ScheduledTaskTrigger -Daily -At '08:00'
$settings=New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Sends privacy-safe aggregate Family Documents daily statistics to the private Telegram operations chat.' -Force|Out-Null
Get-ScheduledTask -TaskName $taskName|Select-Object TaskName,State
