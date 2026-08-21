$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '..\.env.local'
if (Test-Path -LiteralPath $target) {
  throw 'Refusing to overwrite existing .env.local'
}
function New-Secret([int]$bytes) {
  $buffer = [byte[]]::new($bytes)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
  [Convert]::ToBase64String($buffer).Replace('+','-').Replace('/','_').TrimEnd('=')
}
@(
  "POSTGRES_PASSWORD=$(New-Secret 32)"
  "GOTRUE_JWT_SECRET=$(New-Secret 48)"
) | Set-Content -LiteralPath $target -Encoding utf8NoBOM
Write-Output 'Created untracked .env.local with fresh local-only secrets.'
