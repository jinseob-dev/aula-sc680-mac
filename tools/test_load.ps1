Add-Type @"
using System;
using System.Runtime.InteropServices;
public class L {
  [DllImport("kernel32", CharSet=CharSet.Ansi)] public static extern IntPtr LoadLibrary(string n);
  [DllImport("kernel32", CharSet=CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
  [DllImport("kernel32")] public static extern bool FreeLibrary(IntPtr h);
}
"@
$dir = "C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app"
[Environment]::CurrentDirectory = $dir
$h = [L]::LoadLibrary("$dir\hiddriver_8k_orig.dll")
Write-Host "orig load: $h"
if ($h -ne [IntPtr]::Zero) {
  foreach ($n in @("Set_VIDPID","WriteUSB","ReadUSB","Open_ReportDevice")) {
    $p = [L]::GetProcAddress($h, $n)
    Write-Host "$n => $p"
  }
  [L]::FreeLibrary($h) | Out-Null
}
$h2 = [L]::LoadLibrary("$dir\hiddriver_8k.dll")
Write-Host "proxy load: $h2"
