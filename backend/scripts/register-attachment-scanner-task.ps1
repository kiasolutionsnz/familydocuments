$ErrorActionPreference = 'Stop'
$taskName = 'Kia Family Documents Attachment Scanner'
$projectRoot = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $projectRoot 'email-ingestion\attachment-scanner.mjs'
if (-not (Test-Path -LiteralPath $scanner)) { throw "Attachment scanner not found: $scanner" }
$node = (Get-Command node -ErrorAction Stop).Source
$action = New-ScheduledTaskAction -Execute $node -Argument "`"$scanner`" --watch" -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Continuously scans bounded Family Documents email attachments before OCR or classification.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName,State
