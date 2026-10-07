$cs2 = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

public class DriverProbe {
  const string DLL = @"C:\Users\HOME-PC\Desktop\AI\aula\tools\hiddriver_8k.dll";
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Set_VIDPID")]
  public static extern int Set_VIDPID(int vid, int pid);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Set_Device_Version")]
  public static extern int Set_Device_Version(int ver);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Open_ReportDevice")]
  public static extern int Open_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Close_ReportDevice")]
  public static extern int Close_ReportDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Open_FeatureDevice")]
  public static extern int Open_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="Close_FeatureDevice")]
  public static extern int Close_FeatureDevice();
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="WriteUSB")]
  public static extern int WriteUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="ReadUSB")]
  public static extern int ReadUSB(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="GetFeature")]
  public static extern int GetFeature(byte[] buf, int len);
  [DllImport(DLL, CallingConvention=CallingConvention.StdCall, EntryPoint="SetFeature")]
  public static extern int SetFeature(byte[] buf, int len);

  static string Hex(byte[] b, int n){
    var sb=new StringBuilder();
    for(int i=0;i<n;i++) sb.AppendFormat("{0:X2} ", b[i]);
    return sb.ToString().Trim();
  }

  public static void Run() {
    Directory.SetCurrentDirectory(@"C:\Users\HOME-PC\Desktop\AI\aula\tools");
    Console.WriteLine("Is64BitProcess=" + Environment.Is64BitProcess);
    int[,] pairs = new int[,]{ {0x1D57,0xFA65},{0x3554,0xFA09} };
    for (int i=0;i<pairs.GetLength(0);i++) {
      int vid=pairs[i,0], pid=pairs[i,1];
      Console.WriteLine(string.Format("\n==== VID={0:X4} PID={1:X4} ====", vid, pid));
      int r1 = Set_VIDPID(vid, pid);
      Console.WriteLine("Set_VIDPID => " + r1);
      foreach (int ver in new int[]{0,1,2,4,8}) {
        try { Console.WriteLine("Set_Device_Version("+ver+") => " + Set_Device_Version(ver)); }
        catch (Exception ex) { Console.WriteLine(ex.Message); }
      }
      int opened = Open_ReportDevice();
      Console.WriteLine("Open_ReportDevice => " + opened);
      int openedF = Open_FeatureDevice();
      Console.WriteLine("Open_FeatureDevice => " + openedF);

      if (opened != 0) {
        byte[][] cmds = new byte[][] {
          new byte[]{0x0A}, new byte[]{0x01}, new byte[]{0x04}, new byte[]{0x05}, new byte[]{0x0C},
          new byte[]{0x11}, new byte[]{0x12}, new byte[]{0x40}, new byte[]{0x50}, new byte[]{0x80},
          new byte[]{0xA0}, new byte[]{0x00,0x0A}, new byte[]{0x00,0x01}, new byte[]{0x00,0x50},
          new byte[]{0x0A,0x00,0x00,0x00}, new byte[]{0x01,0x01}, new byte[]{0x02,0x01},
          new byte[]{0x0B,0x00}, new byte[]{0x0D,0x00}, new byte[]{0x0E,0x00}, new byte[]{0x0F,0x00},
        };
        foreach (var c in cmds) {
          var wbuf = new byte[64];
          Array.Copy(c, wbuf, Math.Min(c.Length,64));
          int wr = WriteUSB(wbuf, 64);
          var rbuf = new byte[64];
          int rr = ReadUSB(rbuf, 64);
          bool nz=false;
          for(int k=0;k<64;k++) if(rbuf[k]!=0) nz=true;
          Console.WriteLine(string.Format("W[{0}] wr={1} rr={2} {3}", Hex(c,c.Length), wr, rr, nz?Hex(rbuf,32):"(zero/empty)"));
        }
      }
      if (openedF != 0) {
        for (int rid=0; rid<=32; rid++) {
          var buf = new byte[64];
          buf[0]=(byte)rid;
          int gr = GetFeature(buf, 8);
          if (gr != 0) Console.WriteLine(string.Format("GetFeature({0:X2},8)=> {1} {2}", rid, gr, Hex(buf,8)));
          buf = new byte[64];
          buf[0]=(byte)rid;
          gr = GetFeature(buf, 64);
          if (gr != 0) Console.WriteLine(string.Format("GetFeature({0:X2},64)=> {1} {2}", rid, gr, Hex(buf,16)));
        }
      }
      Close_ReportDevice();
      Close_FeatureDevice();
    }
  }
}
'@
Add-Type -TypeDefinition $cs2 -Language CSharp -ErrorAction Stop
[DriverProbe]::Run()
