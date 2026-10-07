$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using System.Threading;

public class WriteProbe {
  const string DLL = @"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app\hiddriver_8k_orig.dll";
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_VIDPID(int vid, int pid);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_Device_Version(int ver);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int WriteUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int ReadUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int SetFeature(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int GetFeature(byte[] buf, int len);

  static string Hex(byte[] b, int n) {
    var sb = new StringBuilder();
    for (int i = 0; i < n && i < b.Length; i++) sb.AppendFormat("{0:X2} ", b[i]);
    return sb.ToString().Trim();
  }

  static void DpiToBytes(int dpi, out byte lo, out byte hi) {
    if (dpi <= 0) { lo = 0; hi = 0; return; }
    int v = (dpi - 50) / 50;
    lo = (byte)(v & 0xFF);
    hi = (byte)((v >> 8) & 0xFF);
  }

  static byte[] BuildDpi(int[] dpis, int activeIndex) {
    var buf = new byte[52];
    buf[0] = 0x04; buf[1] = 0x38; buf[2] = 0x01;
    buf[3] = 0x00; buf[4] = 0x00;
    buf[5] = 0x1F; // 5 slots enabled
    buf[6] = 0x00; buf[7] = 0x00;
    for (int i = 0; i < 5 && i < dpis.Length; i++) {
      byte lo, hi; DpiToBytes(dpis[i], out lo, out hi);
      buf[8 + i] = lo; buf[16 + i] = hi;
      if (dpis[i] > 12000) { buf[6] |= (byte)(1 << i); buf[7] |= (byte)(1 << i); }
    }
    buf[24] = (byte)(activeIndex + 1);
    // colors: simple RGB per slot
    byte[][] colors = new byte[][] {
      new byte[]{255,0,0}, new byte[]{0,255,0}, new byte[]{0,0,255},
      new byte[]{255,0,255}, new byte[]{0,255,255}
    };
    for (int i = 0; i < 5; i++) {
      buf[25 + i*3] = colors[i][0];
      buf[26 + i*3] = colors[i][1];
      buf[27 + i*3] = colors[i][2];
    }
    buf[49] = 2;
    int sum = 0;
    for (int i = 3; i <= 49; i++) sum += buf[i];
    buf[50] = (byte)((sum >> 8) & 0xFF);
    buf[51] = (byte)(sum & 0xFF);
    return buf;
  }

  static void Xfer(string label, byte[] payload, int len) {
    var w = new byte[Math.Max(len, 64)];
    Array.Copy(payload, w, Math.Min(payload.Length, w.Length));
    int wr = WriteUSB(w, len);
    Thread.Sleep(80);
    var r = new byte[64];
    int rr = ReadUSB(r, 64);
    bool nz = false; for (int i = 0; i < 64; i++) if (r[i] != 0) nz = true;
    Console.WriteLine(string.Format("{0}: wr={1} rr={2}", label, wr, rr));
    Console.WriteLine("  TX " + Hex(w, Math.Min(len, 52)));
    if (nz) Console.WriteLine("  RX " + Hex(r, 32));
  }

  public static void Run() {
    Directory.SetCurrentDirectory(@"C:\Users\HOME-PC\Desktop\AI\aula\tools\capture_app");
    Console.WriteLine("Set_VIDPID => " + Set_VIDPID(0x1D57, 0xFA65));
    Console.WriteLine("Open_Feature => " + Open_FeatureDevice());
    Console.WriteLine("Open_Report => " + Open_ReportDevice());

    // Unlock via WriteUSB wrappers
    Xfer("unlock-a", new byte[]{0x04,0x80,0x01,0x03,0x20,0x50,0x00,0x04}, 64);
    Xfer("unlock-b", new byte[]{0x04,0x80,0x01,0x03,0x20,0x41,0x02,0x64}, 64);

    // Full DPI structure as 64-byte output (report id 04)
    var dpi = BuildDpi(new int[]{400,800,1600,3200,6400}, 1);
    var dpi64 = new byte[64]; Array.Copy(dpi, dpi64, dpi.Length);
    Xfer("dpi-write-52pad64", dpi64, 64);
    Xfer("dpi-write-len52", dpi, 52);

    // Rate: try several framings
    Xfer("rate-raw06", new byte[]{0x06,0x09,0x01,0x01,0xFE}, 64); // likely fail
    Xfer("rate-wrap04-06", new byte[]{0x04,0x06,0x09,0x01,0x01,0xFE}, 64);
    Xfer("rate-wrap04-cmd", new byte[]{0x04,0x09,0x01,0x01,0xFE}, 64);

    // Param
    var param = new byte[]{0x05,0x0f,0x01,0x00,0x03,0x04,0x00,0x00,0xff,0x00,0x04,0x00,0x9f};
    Xfer("param-raw05", param, 64);
    var paramWrap = new byte[64]; paramWrap[0]=0x04; Array.Copy(param, 0, paramWrap, 1, param.Length);
    Xfer("param-wrap04", paramWrap, 64);

    // Also SetFeature with full DPI (in case return 0 actually means OK on some paths)
    Console.WriteLine("SetFeature dpi => " + SetFeature(dpi, dpi.Length));
    Console.WriteLine("SetFeature rate => " + SetFeature(new byte[]{0x06,0x09,0x01,0x01,0xFE,0,0,0,0}, 9));

    // Readback attempts via Write then multiple Read
    Xfer("req-dpi", new byte[]{0x04,0x38,0x01}, 64);
    for (int i = 0; i < 5; i++) {
      var r = new byte[64];
      int rr = ReadUSB(r, 64);
      bool nz=false; for(int k=0;k<64;k++) if(r[k]!=0) nz=true;
      Console.WriteLine(string.Format("extra-read {0}: rr={1} {2}", i, rr, nz?Hex(r,24):"(empty)"));
      Thread.Sleep(50);
    }

    Close_ReportDevice();
    Close_FeatureDevice();
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
[WriteProbe]::Run()
