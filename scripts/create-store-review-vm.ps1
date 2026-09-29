<#!
.SYNOPSIS
Creates a clean, isolated Hyper-V guest for FamilyDocuments Store review.

.DESCRIPTION
Creates only a new VM and its dynamic virtual disk under D:\FamilyDocuments.
It intentionally never deletes, replaces, or modifies an existing VM.
#>
[CmdletBinding()]
param(
  [string]$Name = 'FamilyDocuments-StoreReview',
  [string]$Root = 'D:\FamilyDocuments\StoreReviewVM',
  [string]$IsoPath = 'D:\FamilyDocuments\Win11_25H2_EnglishInternational_x64_v2.iso'
)

$ErrorActionPreference = 'Stop'
$vmPath = Join-Path $Root 'vm'
$vhdPath = Join-Path $Root 'disks\FamilyDocuments-StoreReview.vhdx'

if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
  throw "Windows ISO was not found: $IsoPath"
}
if ((Get-Item -LiteralPath $IsoPath).Length -lt 4GB) {
  throw 'Windows ISO is unexpectedly small; refusing to create the VM.'
}
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
  throw "A VM named '$Name' already exists. No changes were made."
}
if (Test-Path -LiteralPath $Root) {
  $existingFiles = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -File)
  if ($existingFiles.Count -gt 0) {
    throw "The target folder contains files: $Root. No changes were made."
  }
}

New-Item -ItemType Directory -Path (Split-Path $vhdPath -Parent) -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

New-VM -Name $Name -Generation 2 -Path $vmPath -NewVHDPath $vhdPath -NewVHDSizeBytes 127GB -MemoryStartupBytes 8GB | Out-Null
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes 4GB -StartupBytes 8GB -MaximumBytes 12GB
Set-VMProcessor -VMName $Name -Count 4
Add-VMDvdDrive -VMName $Name -Path $IsoPath | Out-Null
Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
# Windows 11 requires TPM 2.0.  A local key protector keeps the virtual TPM
# isolated to this host and avoids requiring an external key-management service.
Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
Enable-VMTPM -VMName $Name
Start-VM -Name $Name

Get-VM -Name $Name | Select-Object Name,State,Generation,MemoryAssigned,Path
