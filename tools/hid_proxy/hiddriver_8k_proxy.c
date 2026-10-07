/*
 * Logging proxy for AULA SC680 hiddriver_8k.dll
 * Build (32-bit): zig cc -shared -target x86-windows-gnu -o hiddriver_8k.dll hiddriver_8k_proxy.c
 * Place next to Mouse.exe as hiddriver_8k.dll; keep original as hiddriver_8k_orig.dll
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>

typedef int (__stdcall *Set_VIDPID_t)(int, int);
typedef int (__stdcall *Set_Device_Version_t)(int);
typedef int (__stdcall *Open_ReportDevice_t)(void);
typedef int (__stdcall *Close_ReportDevice_t)(void);
typedef int (__stdcall *Open_FeatureDevice_t)(void);
typedef int (__stdcall *Close_FeatureDevice_t)(void);
typedef int (__stdcall *WriteUSB_t)(unsigned char *, int);
typedef int (__stdcall *ReadUSB_t)(unsigned char *, int);
typedef int (__stdcall *GetFeature_t)(unsigned char *, int);
typedef int (__stdcall *SetFeature_t)(unsigned char *, int);
typedef int (__stdcall *Open_DevMonitor_t)(void *);
typedef int (__stdcall *Close_DevMonitor_t)(void);

static HMODULE g_self;
static HMODULE g_real;
static FILE *g_log;
static CRITICAL_SECTION g_cs;

static Set_VIDPID_t p_Set_VIDPID;
static Set_Device_Version_t p_Set_Device_Version;
static Open_ReportDevice_t p_Open_ReportDevice;
static Close_ReportDevice_t p_Close_ReportDevice;
static Open_FeatureDevice_t p_Open_FeatureDevice;
static Close_FeatureDevice_t p_Close_FeatureDevice;
static WriteUSB_t p_WriteUSB;
static ReadUSB_t p_ReadUSB;
static GetFeature_t p_GetFeature;
static SetFeature_t p_SetFeature;
static Open_DevMonitor_t p_Open_DevMonitor;
static Close_DevMonitor_t p_Close_DevMonitor;

static void log_line(const char *fmt, ...) {
    if (!g_log) return;
    EnterCriticalSection(&g_cs);
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(g_log, "%02d:%02d:%02d.%03d ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_cs);
}

static void log_hex(const char *tag, const unsigned char *buf, int len) {
    if (!g_log || !buf || len <= 0) return;
    EnterCriticalSection(&g_cs);
    fprintf(g_log, "  %s[%d]:", tag, len);
    int n = len > 64 ? 64 : len;
    for (int i = 0; i < n; i++) fprintf(g_log, " %02X", buf[i]);
    if (len > 64) fprintf(g_log, " ...");
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_cs);
}

static int load_real(void) {
    char path[MAX_PATH];
    /* Resolve next to this proxy DLL, not next to the host exe. */
    if (!g_self || !GetModuleFileNameA(g_self, path, MAX_PATH)) {
        log_line("GetModuleFileName(self) failed err=%lu", GetLastError());
        return 0;
    }
    char *slash = strrchr(path, '\\');
    if (slash) *(slash + 1) = 0;
    else path[0] = 0;
    strncat(path, "hiddriver_8k_orig.dll", MAX_PATH - strlen(path) - 1);
    g_real = LoadLibraryA(path);
    if (!g_real) {
        log_line("LoadLibrary failed for %s err=%lu", path, GetLastError());
        return 0;
    }
    log_line("loaded real driver: %s", path);
#define LOAD(name) p_##name = (name##_t)GetProcAddress(g_real, #name)
    LOAD(Set_VIDPID);
    LOAD(Set_Device_Version);
    LOAD(Open_ReportDevice);
    LOAD(Close_ReportDevice);
    LOAD(Open_FeatureDevice);
    LOAD(Close_FeatureDevice);
    LOAD(WriteUSB);
    LOAD(ReadUSB);
    LOAD(GetFeature);
    LOAD(SetFeature);
    LOAD(Open_DevMonitor);
    LOAD(Close_DevMonitor);
#undef LOAD
    return 1;
}

__declspec(dllexport) int __stdcall Set_VIDPID(int vid, int pid) {
    log_line("Set_VIDPID(%04X, %04X)", vid & 0xFFFF, pid & 0xFFFF);
    return p_Set_VIDPID ? p_Set_VIDPID(vid, pid) : 0;
}
__declspec(dllexport) int __stdcall Set_Device_Version(int ver) {
    log_line("Set_Device_Version(%d)", ver);
    return p_Set_Device_Version ? p_Set_Device_Version(ver) : 0;
}
__declspec(dllexport) int __stdcall Open_ReportDevice(void) {
    int r = p_Open_ReportDevice ? p_Open_ReportDevice() : 0;
    log_line("Open_ReportDevice => %d", r);
    return r;
}
__declspec(dllexport) int __stdcall Close_ReportDevice(void) {
    log_line("Close_ReportDevice");
    return p_Close_ReportDevice ? p_Close_ReportDevice() : 0;
}
__declspec(dllexport) int __stdcall Open_FeatureDevice(void) {
    int r = p_Open_FeatureDevice ? p_Open_FeatureDevice() : 0;
    log_line("Open_FeatureDevice => %d", r);
    return r;
}
__declspec(dllexport) int __stdcall Close_FeatureDevice(void) {
    log_line("Close_FeatureDevice");
    return p_Close_FeatureDevice ? p_Close_FeatureDevice() : 0;
}
__declspec(dllexport) int __stdcall WriteUSB(unsigned char *buf, int len) {
    log_line("WriteUSB len=%d", len);
    log_hex("TX", buf, len);
    return p_WriteUSB ? p_WriteUSB(buf, len) : 0;
}
__declspec(dllexport) int __stdcall ReadUSB(unsigned char *buf, int len) {
    int r = p_ReadUSB ? p_ReadUSB(buf, len) : 0;
    log_line("ReadUSB len=%d => %d", len, r);
    if (buf) log_hex("RX", buf, len);
    return r;
}
__declspec(dllexport) int __stdcall GetFeature(unsigned char *buf, int len) {
    int r = p_GetFeature ? p_GetFeature(buf, len) : 0;
    log_line("GetFeature len=%d => %d", len, r);
    if (buf) log_hex("GF", buf, len);
    return r;
}
__declspec(dllexport) int __stdcall SetFeature(unsigned char *buf, int len) {
    log_line("SetFeature len=%d", len);
    log_hex("SF", buf, len);
    return p_SetFeature ? p_SetFeature(buf, len) : 0;
}
__declspec(dllexport) int __stdcall Open_DevMonitor(void *hwnd) {
    log_line("Open_DevMonitor");
    return p_Open_DevMonitor ? p_Open_DevMonitor(hwnd) : 0;
}
__declspec(dllexport) int __stdcall Close_DevMonitor(void) {
    log_line("Close_DevMonitor");
    return p_Close_DevMonitor ? p_Close_DevMonitor() : 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = h;
        DisableThreadLibraryCalls(h);
        InitializeCriticalSection(&g_cs);
        char logpath[MAX_PATH];
        GetTempPathA(MAX_PATH, logpath);
        strncat(logpath, "sc680_hid_capture.log", MAX_PATH - strlen(logpath) - 1);
        g_log = fopen(logpath, "a");
        log_line("=== proxy attached, log=%s ===", logpath);
        if (!load_real()) {
            log_line("FATAL: real driver load failed");
            return FALSE;
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        log_line("=== proxy detach ===");
        if (g_real) FreeLibrary(g_real);
        if (g_log) fclose(g_log);
        DeleteCriticalSection(&g_cs);
    }
    return TRUE;
}
