$cs = @'
using System;
using System.Runtime.InteropServices;
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
    var bad = new byte[64]; bad[0]=0x06; bad[1]=0x09; bad[2]=0x01; bad[3]=0x01; bad[4]=0xFE;
    if (WriteUSB(bad, 64) != 0) return 20;
    var dpi = new byte[64];
    dpi[0]=0x04; dpi[1]=0x38; dpi[2]=0x01; dpi[5]=0x1F; dpi[24]=0x02;
    dpi[8]=0x07; dpi[9]=0x0F; dpi[10]=0x1F; dpi[11]=0x3F; dpi[12]=0x7F;
    int sum=0; for(int i=3;i<=49;i++) sum+=dpi[i];
    dpi[50]=(byte)((sum>>8)&0xFF); dpi[51]=(byte)(sum&0xFF);
    if (WriteUSB(dpi, 64) != 1) return 21;
    var rate = new byte[64];
    rate[0]=0x04; rate[1]=0x06; rate[2]=0x09; rate[3]=0x01; rate[4]=0x01; rate[5]=0xFE;
    if (WriteUSB(rate, 64) != 1) return 22;
    Close_ReportDevice(); Close_FeatureDevice();
    return 0;
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
$code = [Verify]::Run()
Write-Output "VERIFY_EXIT=$code"
exit $code
