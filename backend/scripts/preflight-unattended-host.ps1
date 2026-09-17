[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ReportPath)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$report = [ordered]@{
  observed_at = (Get-Date).ToString('o')
  is_administrator = $isAdmin
  status = 'READ_ONLY_PREFLIGHT'
}
if ($isAdmin) {
  $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
  $report.hyper_v_feature = if ($feature) { [string]$feature.State } else { 'Unavailable' }
  try {
    $hostInfo = Get-VMHost -ErrorAction Stop
    $report.vm_host_available = $true
    $report.default_vm_path_configured = [bool]$hostInfo.VirtualMachinePath
    $report.default_vhd_path_configured = [bool]$hostInfo.VirtualHardDiskPath
    $report.existing_vm_count = @((Get-VM -ErrorAction Stop)).Count
    $report.vm_switches = @((Get-VMSwitch -ErrorAction Stop) | ForEach-Object {
      [ordered]@{ name = $_.Name; switch_type = [string]$_.SwitchType }
    })
  } catch {
    $report.vm_host_available = $false
    $report.vm_host_error_type = $_.Exception.GetType().Name
  }
  $service = Get-Service com.docker.service -ErrorAction Stop
  $report.docker_desktop_helper_service_status = [string]$service.Status
  $report.docker_desktop_helper_service_start_type = [string]$service.StartType
  $computer = Get-CimInstance Win32_ComputerSystem
  $os = Get-CimInstance Win32_OperatingSystem
  $report.physical_memory_gib = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
  $report.free_memory_gib = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
  $taskNames = @(
    'Kia Family Documents Attachment Scanner',
    'Kia Family Documents Classifier',
    'Kia Family Documents Notifications',
    'Kia Family Documents Inbound Email Health',
    'Kia Family Documents AI OCR Health',
    'Kia Family Documents Daily Stats'
  )
  $report.familydocuments_tasks = @($taskNames | ForEach-Object {
    $task = Get-ScheduledTask -TaskName $_ -ErrorAction Stop
    $taskInfo = Get-ScheduledTaskInfo -TaskName $_ -ErrorAction Stop
    [ordered]@{
      name = $_
      logon_type = [string]$task.Principal.LogonType
      trigger_type = [string]$task.Triggers[0].CimClass.CimClassName
      state = [string]$task.State
      last_run_time = $taskInfo.LastRunTime.ToString('o')
      last_task_result = $taskInfo.LastTaskResult
      next_run_time = $taskInfo.NextRunTime.ToString('o')
    }
  })
}
$fullReport = [IO.Path]::GetFullPath($ReportPath)
$backupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../backups'))
if (-not $fullReport.StartsWith($backupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Report path must be inside ignored backend/backups.'
}
$parent = Split-Path -Path $fullReport -Parent
if (-not (Test-Path -LiteralPath $parent)) { throw 'Report parent does not exist.' }
if (Test-Path -LiteralPath $fullReport) { throw 'Report already exists; refusing overwrite.' }
[IO.File]::WriteAllText($fullReport, ($report | ConvertTo-Json -Depth 5), [Text.Encoding]::UTF8)
Write-Output "Preflight report written; administrator=$isAdmin"
