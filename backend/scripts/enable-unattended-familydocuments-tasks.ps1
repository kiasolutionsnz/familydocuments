[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$names = @(
  'Kia Family Documents Attachment Scanner',
  'Kia Family Documents Classifier',
  'Kia Family Documents Notifications',
  'Kia Family Documents Inbound Email Health',
  'Kia Family Documents AI OCR Health',
  'Kia Family Documents Daily Stats'
)
$watchers = @(
  'Kia Family Documents Attachment Scanner',
  'Kia Family Documents Classifier',
  'Kia Family Documents Notifications'
)

$current = @{}
foreach ($name in $names) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
  if ($task.TaskPath -ne '\') { throw "Unexpected task path for $name" }
  if ($task.Principal.LogonType -notin @('Interactive', 'S4U')) {
    throw "Unexpected logon type for $name"
  }
  if ($task.Actions.Count -ne 1 -or $task.Triggers.Count -ne 1) {
    throw "Unexpected action or trigger count for $name"
  }
  $current[$name] = $task
}

if (-not $Apply) {
  $names | ForEach-Object {
    [pscustomobject]@{
      Name = $_
      CurrentLogonType = $current[$_].Principal.LogonType
      CurrentTrigger = $current[$_].Triggers[0].CimClass.CimClassName
      TargetLogonType = 'S4U'
      TargetTrigger = if ($_ -in $watchers) { 'AtStartup' } else { 'PreserveExisting' }
    }
  }
  return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Run this script in an elevated PowerShell window. No task was changed.'
}

$backupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../backups'))
$backupDir = Join-Path $backupRoot ('fd-task-s4u-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (-not $backupDir.StartsWith($backupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Task backup path escaped backend/backups.'
}
New-Item -ItemType Directory -Path $backupDir -ErrorAction Stop | Out-Null
$originalXml = @{}
foreach ($name in $names) {
  $xml = Export-ScheduledTask -TaskName $name -ErrorAction Stop
  $originalXml[$name] = $xml
  $safeName = $name -replace '[^A-Za-z0-9-]', '-'
  [IO.File]::WriteAllText((Join-Path $backupDir "$safeName.xml"), $xml, [Text.Encoding]::Unicode)
}

$changed = [Collections.Generic.List[string]]::new()
try {
  foreach ($name in $names) {
    $old = $current[$name]
    $newPrincipal = New-ScheduledTaskPrincipal -UserId $old.Principal.UserId -LogonType S4U -RunLevel $old.Principal.RunLevel
    $changed.Add($name)
    if ($name -in $watchers) {
      $trigger = New-ScheduledTaskTrigger -AtStartup
      Set-ScheduledTask -TaskName $name -Principal $newPrincipal -Trigger $trigger -ErrorAction Stop | Out-Null
    } else {
      Set-ScheduledTask -TaskName $name -Principal $newPrincipal -ErrorAction Stop | Out-Null
    }
    $updated = Get-ScheduledTask -TaskName $name -ErrorAction Stop
    if ($updated.Principal.LogonType -ne 'S4U') { throw "S4U verification failed for $name" }
    if ($name -in $watchers -and $updated.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskBootTrigger') {
      throw "Startup trigger verification failed for $name"
    }
  }
} catch {
  $failure = $_
  $rollbackErrors = [Collections.Generic.List[string]]::new()
  foreach ($name in $changed) {
    try {
      Register-ScheduledTask -TaskName $name -Xml $originalXml[$name] -Force -ErrorAction Stop | Out-Null
    } catch {
      $rollbackErrors.Add($name)
    }
  }
  if ($rollbackErrors.Count) {
    throw "Task conversion failed; automatic rollback also failed for: $($rollbackErrors -join ', '). Original XML is in $backupDir. Failure: $failure"
  }
  throw "Task conversion failed; changed tasks were rolled back. Original XML is in $backupDir. Failure: $failure"
}

[pscustomobject]@{
  Status = 'TASK_REGISTRATION_UPDATED_NOT_REBOOT_VERIFIED'
  Count = $changed.Count
  BackupDirectory = $backupDir
  CurrentWorkerInstancesWereNotRestarted = $true
  DockerEngineNoLoginStartupWasNotChanged = $true
}
