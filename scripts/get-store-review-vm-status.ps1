$ErrorActionPreference = 'Stop'
$result = [ordered]@{ checked_at = (Get-Date).ToString('o') }
try {
  $vm = Get-VM -Name 'FamilyDocuments-StoreReview' -ErrorAction SilentlyContinue
  $result.vm = if ($null -eq $vm) { $null } else {
    $vm | Select-Object Name,State,Generation,MemoryAssigned,Path
  }
  $result.target_folder_exists = Test-Path -LiteralPath 'D:\FamilyDocuments\StoreReviewVM'
  $result.iso_exists = Test-Path -LiteralPath 'D:\FamilyDocuments\Win11_25H2_EnglishInternational_x64_v2.iso'
  $result.status = 'ok'
} catch {
  $result.status = 'error'
  $result.error = $_.Exception.Message
}
$result | ConvertTo-Json -Depth 4 |
  Set-Content -LiteralPath 'C:\Users\Inder\My Codex Apps\familydocuments-phase2f-baseline\scripts\store-review-vm-status.json' -Encoding utf8
