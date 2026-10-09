#include <windows.h>
__declspec(dllexport) int __stdcall Set_VIDPID(int vid, int pid) { return vid + pid; }
__declspec(dllexport) int __stdcall Set_Device_Version(int version) { return version + 1; }
__declspec(dllexport) int __stdcall Open_ReportDevice(void) { return 11; }
__declspec(dllexport) int __stdcall Close_ReportDevice(void) { return 12; }
__declspec(dllexport) int __stdcall Open_FeatureDevice(void) { return 13; }
__declspec(dllexport) int __stdcall Close_FeatureDevice(void) { return 14; }
__declspec(dllexport) int __stdcall WriteUSB(unsigned char *buf, int len) { return len == 65 && buf[0] == 4 && buf[64] == 0xAB ? 23 : -1; }
__declspec(dllexport) int __stdcall ReadUSB(unsigned char *buf, int len) { if (len != 65) return -1; buf[0] = 3; buf[64] = 0xCD; return 24; }
__declspec(dllexport) int __stdcall GetFeature(unsigned char *buf, int len) { buf[0] = 0xEF; return len + 1; }
__declspec(dllexport) int __stdcall SetFeature(unsigned char *buf, int len) { return len == 65 && buf[64] == 0xAB ? 25 : -1; }
__declspec(dllexport) int __stdcall Open_DevMonitor(void *window) { return window == (void *)123 ? 15 : -1; }
__declspec(dllexport) int __stdcall Close_DevMonitor(void) { return 16; }
