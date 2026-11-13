# Installs asmspeed for the current user (no admin rights needed):
#   copies asmspeed.exe to %LOCALAPPDATA%\Programs\asmspeed and adds that folder to your user PATH.
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\asmspeed'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'asmspeed.exe') $dest

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$parts = $userPath -split ';' | Where-Object { $_ -ne '' }
if ($parts -notcontains $dest) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $dest) -join ';'), 'User')
    Write-Host "Added $dest to your user PATH."
}
Write-Host "asmspeed installed to $dest"
Write-Host "Open a NEW terminal and run:  asmspeed"
