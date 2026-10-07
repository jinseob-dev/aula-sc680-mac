$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using System.Threading;

public class FeatureProbe {
  const string DLL = @"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app\hiddriver_8k_orig.dll";
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_VIDPID(int vid, int pid);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_Device_Version(int ver);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int WriteUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int ReadUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int GetFeature(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int SetFeature(byte[] buf, int len);

  static string Hex(byte[] b, int n) {
    var sb = new StringBuilder();
    for (int i = 0; i < n && i < b.Length; i++) sb.AppendFormat("{0:X2} ", b[i]);
    return sb.ToString().Trim();
  }

  static void TryGet(string label, byte rid, int len) {
    var buf = new byte[len];
    buf[0] = rid;
    int r = GetFeature(buf, len);
    bool nz = false;
    for (int i = 0; i < len; i++) if (buf[i] != 0) { nz = true; break; }
    Console.WriteLine(string.Format("{0}: GetFeature(id={1:X2},len={2}) => {3} {4}", label, rid, len, r, nz ? Hex(buf, Math.Min(len, 52)) : "(zero)"));
  }

  static void TrySet(string label, byte[] data) {
    int r = SetFeature(data, data.Length);
    Console.WriteLine(string.Format("{0}: SetFeature(len={1}) => {2} TX {3}", label, data.Length, r, Hex(data, Math.Min(data.Length, 24))));
  }

  static void TryWrite(string label, byte[] data) {
    var w = new byte[64];
    Array.Copy(data, w, Math.Min(data.Length, 64));
    int wr = WriteUSB(w, 64);
    var rb = new byte[64];
    int rr = ReadUSB(rb, 64);
    bool nz = false;
    for (int i = 0; i < 64; i++) if (rb[i] != 0) { nz = true; break; }
    Console.WriteLine(string.Format("{0}: WriteUSB=>{1} ReadUSB=>{2}", label, wr, rr));
    Console.WriteLine("  TX " + Hex(w, 24));
    if (nz) Console.WriteLine("  RX " + Hex(rb, 32));
  }

  public static void Run() {
    Directory.SetCurrentDirectory(@"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app");
    Console.WriteLine("Set_VIDPID => " + Set_VIDPID(0x1D57, 0xFA65));
    Console.WriteLine("Set_Device_Version(8) => " + Set_Device_Version(8));
    Console.WriteLine("Open_FeatureDevice => " + Open_FeatureDevice());
    Console.WriteLine("Open_ReportDevice => " + Open_ReportDevice());

    // Beken feature report sizes
    TryGet("battery", 0x01, 7);
    TryGet("dpi52", 0x04, 52);
    TryGet("dpi64", 0x04, 64);
    TryGet("param13", 0x05, 13);
    TryGet("param64", 0x05, 64);
    TryGet("rate9", 0x06, 9);
    TryGet("rate64", 0x06, 64);
    TryGet("button59", 0x08, 59);
    TryGet("button64", 0x08, 64);
    TryGet("apply", 0x0C, 8);
    TryGet("unlock", 0x80, 7);

    // Unlock sequence from bekken driver
    TrySet("unlock1", new byte[]{0x80,0x01,0x03,0x20,0x50,0x00,0x04});
    TrySet("unlock2", new byte[]{0x80,0x01,0x03,0x20,0x41,0x02,0x64});
    Thread.Sleep(50);

    TryGet("dpi52-after-unlock", 0x04, 52);
    TryGet("rate9-after-unlock", 0x06, 9);
    TryGet("param13-after-unlock", 0x05, 13);
    TryGet("button59-after-unlock", 0x08, 59);
    TryGet("battery-after-unlock", 0x01, 7);

    // Also try WriteUSB with full bekken DPI get-shaped / unlock frames
    TryWrite("w-unlock1", new byte[]{0x04,0x80,0x01,0x03,0x20,0x50,0x00,0x04});
    TryWrite("w-dpi-id", new byte[]{0x04,0x38,0x01});
    var dpi = new byte[52];
    dpi[0]=0x04; dpi[1]=0x38; dpi[2]=0x01;
    TrySet("set-dpi-empty", dpi);

    var rate = new byte[]{0x06,0x09,0x01,0x01,0xFE,0,0,0,0};
    TrySet("set-rate-1000", rate);

    Close_ReportDevice();
    Close_FeatureDevice();
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
[FeatureProbe]::Run()
