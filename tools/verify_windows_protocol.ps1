# Validates SC680 Beken/8K transport assumptions used by the Mac app.
$ErrorActionPreference = "Stop"
$root = "C:\Users\HOME-PC\Desktop\AI\aula"
$out = Join-Path $root "docs\fixtures\windows_verify_result.txt"

$script = @'
$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

public class Verify {
  const string DLL = @"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app\hiddriver_8k_orig.dll";
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_VIDPID(int vid, int pid);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int WriteUSB(byte[] buf, int len);

  public static int Run() {
    Directory.SetCurrentDirectory(@"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app");
    if (Set_VIDPID(0x1D57, 0xFA65) != 1) return 10;
    if (Open_FeatureDevice() != 1) return 11;
    if (Open_ReportDevice() != 1) return 12;
    // Reject non-04 report id
    var bad = new byte[64]; bad[0]=0x06; bad[1]=0x09; bad[2]=0x01; bad[3]=0x01; bad[4]=0xFE;
    if (WriteUSB(bad, 64) != 0) return 20;
    // Accept DPI packet
    var dpi = new byte[64];
    dpi[0]=0x04; dpi[1]=0x38; dpi[2]=0x01; dpi[5]=0x1F; dpi[24]=0x02;
    dpi[8]=0x07; dpi[9]=0x0F; dpi[10]=0x1F; dpi[11]=0x3F; dpi[12]=0x7F;
    int sum=0; for(int i=3;i<=49;i++) sum+=dpi[i];
    dpi[50]=(byte)((sum>>8)&0xFF); dpi[51]=(byte)(sum&0xFF);
    if (WriteUSB(dpi, 64) != 1) return 21;
    // Accept wrapped rate
    var rate = new byte[64];
    rate[0]=0x04; rate[1]=0x06; rate[2]=0x09; rate[3]=0x01; rate[4]=0x01; rate[5]=0xFE;
    if (WriteUSB(rate, 64) != 1) return 22;
    Close_ReportDevice(); Close_FeatureDevice();
    return 0;
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp
$code = [Verify]::Run()
Write-Output $code
'@

Get-Process Mouse -ErrorAction SilentlyContinue | Stop-Process -Force
$code = & "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command $script
$lines = @(
  "timestamp=$(Get-Date -Format o)",
  "verify_exit=$code",
  "expected=0 (all transport checks passed)",
  "dongle=1D57:FA65",
  "checks=reject_report06,accept_dpi04,accept_wrapped_rate"
)
$lines | Set-Content -Path $out -Encoding UTF8
Write-Host ($lines -join "`n")
if ([int]$code -ne 0) { exit [int]$code }
