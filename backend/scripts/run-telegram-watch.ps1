$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
& node '.\telegram\worker.mjs' --watch
exit $LASTEXITCODE
