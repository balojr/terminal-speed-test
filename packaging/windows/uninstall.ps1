# Removes asmspeed installed by install.ps1.
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\asmspeed'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $parts = $userPath -split ';' | Where-Object { $_ -ne '' -and $_ -ne $dest }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Write-Host "asmspeed removed."
