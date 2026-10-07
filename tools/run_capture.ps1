# Prepare a private copy of the OEM app with logging proxy DLL.
$ErrorActionPreference = "Stop"
$root = "C:\Users\HOME-PC\Desktop\AI\aula"
$src = Join-Path $root "sc680-windows"
$dst = Join-Path $root "tools\capture_app"
$proxy = Join-Path $root "tools\hid_proxy\hiddriver_8k.dll"
$log = Join-Path $env:TEMP "sc680_hid_capture.log"

if (-not (Test-Path "$src\Mouse.exe")) { throw "Missing $src\Mouse.exe" }
if (-not (Test-Path $proxy)) { throw "Missing proxy DLL: $proxy" }

New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
Copy-Item "$dst\hiddriver_8k.dll" "$dst\hiddriver_8k_orig.dll" -Force
Copy-Item $proxy "$dst\hiddriver_8k.dll" -Force

if (Test-Path $log) { Remove-Item $log -Force }
Write-Host "Log: $log"
Write-Host "Launching Mouse.exe — change DPI/polling/button then close the app."
Start-Process -FilePath "$dst\Mouse.exe" -WorkingDirectory $dst
Start-Sleep -Seconds 2
if (Test-Path $log) {
  Write-Host "=== log so far ==="
  Get-Content $log
} else {
  Write-Host "Log not created yet (proxy may not have loaded)."
}
