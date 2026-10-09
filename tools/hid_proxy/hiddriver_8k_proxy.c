/*
 * Logging proxy for AULA SC680 hiddriver_8k.dll
 * Build (32-bit): zig cc -shared -target x86-windows-gnu -o hiddriver_8k.dll hiddriver_8k_proxy.c
 * Place next to Mouse.exe as hiddriver_8k.dll; keep original as hiddriver_8k_orig.dll
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

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
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;

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
    int n = len > 256 ? 256 : len;
    for (int i = 0; i < n; i++) fprintf(g_log, " %02X", buf[i]);
    if (len > 256) fprintf(g_log, " ...");
    fputc('\n', g_log);
    fflush(g_log);
    LeaveCriticalSection(&g_cs);
}

static BOOL CALLBACK initialize(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    wchar_t path[MAX_PATH], logpath[32768];
    DWORD n;
    (void)once; (void)parameter; (void)context;
    n = GetEnvironmentVariableW(L"SC680_CAPTURE_LOG", logpath, 32768);
    if (n == 0 || n >= 32768) return FALSE;
    g_log = _wfopen(logpath, L"a");
    if (!g_log) return FALSE;
    log_line("=== proxy initialized ===");
    n = GetModuleFileNameW(g_self, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return FALSE;
    wchar_t *slash = wcsrchr(path, L'\\');
    if (!slash) return FALSE;
    *(slash + 1) = 0;
    const wchar_t *original = L"hiddriver_8k_orig.dll";
    if (wcslen(path) + wcslen(original) >= MAX_PATH) return FALSE;
    wcscat(path, original);
    g_real = LoadLibraryW(path);
    if (!g_real) { log_line("LoadLibrary failed err=%lu", GetLastError()); return FALSE; }
#define LOAD(name) p_##name = (name##_t)GetProcAddress(g_real, #name); if (!p_##name) { log_line("Missing export " #name); return FALSE; }
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
    log_line("Loaded original driver; forwarding without modifying packets");
    return TRUE;
}

static int ensure_ready(void) { return InitOnceExecuteOnce(&g_init, initialize, NULL, NULL) != 0; }

__declspec(dllexport) int __stdcall Set_VIDPID(int vid, int pid) {
    if (!ensure_ready()) return 0;
    log_line("Set_VIDPID(%04X, %04X)", vid & 0xFFFF, pid & 0xFFFF);
    return p_Set_VIDPID ? p_Set_VIDPID(vid, pid) : 0;
}
__declspec(dllexport) int __stdcall Set_Device_Version(int ver) {
    if (!ensure_ready()) return 0;
    log_line("Set_Device_Version(%d)", ver);
    return p_Set_Device_Version ? p_Set_Device_Version(ver) : 0;
}
__declspec(dllexport) int __stdcall Open_ReportDevice(void) {
    if (!ensure_ready()) return 0;
    int r = p_Open_ReportDevice ? p_Open_ReportDevice() : 0;
    log_line("Open_ReportDevice => %d", r);
    return r;
}
__declspec(dllexport) int __stdcall Close_ReportDevice(void) {
    if (!ensure_ready()) return 0;
    log_line("Close_ReportDevice");
    return p_Close_ReportDevice ? p_Close_ReportDevice() : 0;
}
__declspec(dllexport) int __stdcall Open_FeatureDevice(void) {
    if (!ensure_ready()) return 0;
    int r = p_Open_FeatureDevice ? p_Open_FeatureDevice() : 0;
    log_line("Open_FeatureDevice => %d", r);
    return r;
}
__declspec(dllexport) int __stdcall Close_FeatureDevice(void) {
    if (!ensure_ready()) return 0;
    log_line("Close_FeatureDevice");
    return p_Close_FeatureDevice ? p_Close_FeatureDevice() : 0;
}
__declspec(dllexport) int __stdcall WriteUSB(unsigned char *buf, int len) {
    if (!ensure_ready()) return 0;
    log_line("WriteUSB len=%d", len);
    log_hex("TX", buf, len);
    int r = p_WriteUSB(buf, len);
    log_line("WriteUSB => %d", r);
    return r;
}
__declspec(dllexport) int __stdcall ReadUSB(unsigned char *buf, int len) {
    if (!ensure_ready()) return 0;
    int r = p_ReadUSB ? p_ReadUSB(buf, len) : 0;
    log_line("ReadUSB len=%d => %d", len, r);
    if (buf) log_hex("RX", buf, len);
    return r;
}
__declspec(dllexport) int __stdcall GetFeature(unsigned char *buf, int len) {
    if (!ensure_ready()) return 0;
    int r = p_GetFeature ? p_GetFeature(buf, len) : 0;
    log_line("GetFeature len=%d => %d", len, r);
    if (buf) log_hex("GF", buf, len);
    return r;
}
__declspec(dllexport) int __stdcall SetFeature(unsigned char *buf, int len) {
    if (!ensure_ready()) return 0;
    log_line("SetFeature len=%d", len);
    log_hex("SF", buf, len);
    return p_SetFeature ? p_SetFeature(buf, len) : 0;
}
__declspec(dllexport) int __stdcall Open_DevMonitor(void *hwnd) {
    if (!ensure_ready()) return 0;
    log_line("Open_DevMonitor");
    return p_Open_DevMonitor ? p_Open_DevMonitor(hwnd) : 0;
}
__declspec(dllexport) int __stdcall Close_DevMonitor(void) {
    if (!ensure_ready()) return 0;
    log_line("Close_DevMonitor");
    return p_Close_DevMonitor ? p_Close_DevMonitor() : 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = h;
        DisableThreadLibraryCalls(h);
        InitializeCriticalSection(&g_cs);
    }
    /* No loading, file IO, or FreeLibrary under the DllMain loader lock. */
    return TRUE;
}
