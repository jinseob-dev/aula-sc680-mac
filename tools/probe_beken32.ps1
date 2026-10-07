$cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

public class BekenDllProbe {
  const string DLL = @"C:\Users\HOME-PC\Desktop\AI\aula\tools\hiddriver_8k.dll";
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_VIDPID(int vid, int pid);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Set_Device_Version(int ver);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Open_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int Close_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int WriteUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall)] public static extern int ReadUSB(byte[] buf, int len);

  static string Hex(byte[] b, int n) {
    var sb = new StringBuilder();
    for (int i = 0; i < n; i++) sb.AppendFormat("{0:X2} ", b[i]);
    return sb.ToString().Trim();
  }

  static void Xfer(string label, byte[] payload) {
    var w = new byte[64];
    Array.Copy(payload, w, Math.Min(payload.Length, 64));
    int wr = WriteUSB(w, 64);
    var r = new byte[64];
    int rr = ReadUSB(r, 64);
    bool nz = false;
    for (int i = 0; i < 64; i++) if (r[i] != 0) { nz = true; break; }
    Console.WriteLine(string.Format("{0}: wr={1} rr={2}", label, wr, rr));
    Console.WriteLine("  TX " + Hex(w, 16));
    if (nz || rr != 0) Console.WriteLine("  RX " + Hex(r, 32));
    else Console.WriteLine("  RX (empty)");
  }

  public static void Run() {
    Directory.SetCurrentDirectory(@"C:\Users\HOME-PC\Desktop\AI\aula\tools");
    Console.WriteLine("Is64=" + Environment.Is64BitProcess);
    Console.WriteLine("Set_VIDPID => " + Set_VIDPID(0x1D57, 0xFA65));
    Console.WriteLine("Set_Device_Version(8) => " + Set_Device_Version(8));
    Console.WriteLine("Open_ReportDevice => " + Open_ReportDevice());

    // Report ID 0x04 is the only valid OUT id on this dongle.
    // Try Beken-like command bytes at offset 1, and also packed as whole feature-style structs.
    byte[][] cmds = new byte[][] {
      // bare
      new byte[]{0x04},
      // unlock / apply style
      new byte[]{0x04, 0x80},
      new byte[]{0x04, 0x0C},
      new byte[]{0x04, 0x01},
      // beken report ids as commands
      new byte[]{0x04, 0x04},
      new byte[]{0x04, 0x05},
      new byte[]{0x04, 0x06},
      new byte[]{0x04, 0x08},
      new byte[]{0x04, 0x0A},
      // beken command field values from driver-beken.c
      new byte[]{0x04, 0x38, 0x01}, // DPI command
      new byte[]{0x04, 0x0F, 0x01}, // PARAM command
      new byte[]{0x04, 0x09, 0x01}, // RATE command
      new byte[]{0x04, 0x3B, 0x01}, // BUTTON command
      // get variants (command | 0x80) sometimes used
      new byte[]{0x04, 0xB8, 0x01},
      new byte[]{0x04, 0x8F, 0x01},
      new byte[]{0x04, 0x89, 0x01},
      new byte[]{0x04, 0xBB, 0x01},
      // length-prefixed
      new byte[]{0x04, 0x04, 0x00},
      new byte[]{0x04, 0x06, 0x00},
      new byte[]{0x04, 0x01, 0x00},
      new byte[]{0x04, 0x02, 0x00},
      new byte[]{0x04, 0x03, 0x00},
      new byte[]{0x04, 0x07, 0x00},
      new byte[]{0x04, 0x10, 0x00},
      new byte[]{0x04, 0x11, 0x00},
      new byte[]{0x04, 0x12, 0x00},
      new byte[]{0x04, 0x20, 0x00},
      new byte[]{0x04, 0x21, 0x00},
      new byte[]{0x04, 0x30, 0x00},
      new byte[]{0x04, 0x40, 0x00},
      new byte[]{0x04, 0x50, 0x00},
      new byte[]{0x04, 0x60, 0x00},
      new byte[]{0x04, 0x70, 0x00},
      new byte[]{0x04, 0x90, 0x00},
      new byte[]{0x04, 0xA0, 0x00},
      new byte[]{0x04, 0xB0, 0x00},
      new byte[]{0x04, 0xC0, 0x00},
      new byte[]{0x04, 0xD0, 0x00},
      new byte[]{0x04, 0xE0, 0x00},
      new byte[]{0x04, 0xF0, 0x00},
    };

    foreach (var c in cmds) {
      Xfer(Hex(c, c.Length), c);
    }

    // Full Beken DPI get-shaped buffer (report 04, cmd 38, profile 01)
    var dpi = new byte[64];
    dpi[0] = 0x04; dpi[1] = 0x38; dpi[2] = 0x01;
    Xfer("dpi-shaped", dpi);

    var rate = new byte[64];
    rate[0] = 0x04; rate[1] = 0x09; rate[2] = 0x01; rate[3] = 0x01; rate[4] = 0xFE;
    Xfer("rate-shaped", rate);

    Close_ReportDevice();
  }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
[BekenDllProbe]::Run()
