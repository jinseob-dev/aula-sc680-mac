param([string]$OEMDirectory)
$ErrorActionPreference = "Stop"
if (Get-Process Mouse -ErrorAction SilentlyContinue) {
    throw "Close the AULA Windows program (including its tray icon), then run this tool again."
}
if (-not $OEMDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.OpenFileDialog
    $picker.Title = "Select Mouse.exe in the installed AULA SC680 8K program folder"
    $picker.Filter = "AULA program (Mouse.exe)|Mouse.exe"
    if ($picker.ShowDialog() -ne "OK") { exit 0 }
    $OEMDirectory = Split-Path -Parent $picker.FileName
}
$src = (Resolve-Path -LiteralPath $OEMDirectory).Path
$proxy = Join-Path $PSScriptRoot "hid_proxy\hiddriver_8k.dll"
foreach ($file in @("Mouse.exe", "hiddriver_8k.dll")) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $file) -PathType Leaf)) { throw "Missing OEM file: $file" }
}
if (-not (Test-Path -LiteralPath $proxy -PathType Leaf)) { throw "Extract the complete capture ZIP before running this tool." }
# Work only in a new copy; never replace files in the installed program.
$destination = Join-Path $env:TEMP ("SC680-capture-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $destination | Out-Null
Get-ChildItem -LiteralPath $src -Force | Copy-Item -Destination $destination -Recurse -Force
Rename-Item -LiteralPath (Join-Path $destination "hiddriver_8k.dll") -NewName "hiddriver_8k_orig.dll"
Copy-Item -LiteralPath $proxy -Destination (Join-Path $destination "hiddriver_8k.dll")
$output = Join-Path $PSScriptRoot ("capture-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $output | Out-Null
$log = Join-Path $output "sc680_hid_capture.log"
@("SC680 capture; private OEM binaries are excluded from this output folder.",
  "Mouse.exe SHA256: " + (Get-FileHash -LiteralPath (Join-Path $src "Mouse.exe") -Algorithm SHA256).Hash,
  "Driver SHA256: " + (Get-FileHash -LiteralPath (Join-Path $src "hiddriver_8k.dll") -Algorithm SHA256).Hash) |
    Set-Content -LiteralPath (Join-Path $output "metadata.txt") -Encoding UTF8
$previousLog = $env:SC680_CAPTURE_LOG
try {
    $env:SC680_CAPTURE_LOG = $log
    Write-Host "1. Keep the 8K receiver connected and select it in the AULA program."
    Write-Host "2. Change ONLY the current DPI stage's color, then click Apply once."
    Write-Host "3. Do not cycle the physical DPI button. Note whether the color changes immediately."
    Write-Host "4. Exit the AULA program completely (also close its tray icon)."
    Start-Process -FilePath (Join-Path $destination "Mouse.exe") -WorkingDirectory $destination -Wait
} finally {
    $env:SC680_CAPTURE_LOG = $previousLog
}
if (-not (Test-Path -LiteralPath $log)) { throw "No log created. The program may have reused a running instance or another driver. Close it and retry." }
if (-not (Select-String -LiteralPath $log -SimpleMatch "WriteUSB len=" -Quiet)) {
    Write-Warning "No output was recorded. Check that the 8K receiver was selected and Apply was clicked."
}
Write-Host "Upload ONLY sc680_hid_capture.log and metadata.txt from: $output"
Write-Host "The temporary OEM copy remains at: $destination (it can be deleted after the app exits)."
Start-Process explorer.exe -ArgumentList $output
