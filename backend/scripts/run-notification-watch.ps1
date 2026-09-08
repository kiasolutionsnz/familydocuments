$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $root
& node '.\notifications\worker.mjs' --watch
exit $LASTEXITCODE
