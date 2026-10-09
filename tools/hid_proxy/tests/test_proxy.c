#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int (__stdcall *Pair)(int,int);
typedef int (__stdcall *Integer)(int);
typedef int (__stdcall *None)(void);
typedef int (__stdcall *Buffer)(unsigned char *, int);
typedef int (__stdcall *Monitor)(void *);
#define CHECK(value) do { if (!(value)) { fprintf(stderr, "FAIL line %d\n", __LINE__); exit(1); } } while (0)
#define FN(type,name) ((type)GetProcAddress(driver,name))
int main(void) {
    unsigned char bytes[65] = {4};
    char log[32768];
    CHECK(SetEnvironmentVariableA("SC680_CAPTURE_LOG", "proxy-test.log"));
    HMODULE driver = LoadLibraryA("hiddriver_8k.dll");
    CHECK(driver != NULL);
    const char *exports[] = {"Set_VIDPID","Set_Device_Version","Open_ReportDevice","Close_ReportDevice",
        "Open_FeatureDevice","Close_FeatureDevice","WriteUSB","ReadUSB","GetFeature","SetFeature","Open_DevMonitor","Close_DevMonitor"};
    for (int i = 0; i < 12; i++) CHECK(GetProcAddress(driver, exports[i]) != NULL);
    CHECK(FN(Pair,"Set_VIDPID")(0x1D57,0xFA65) == 0x117BC);
    CHECK(FN(Integer,"Set_Device_Version")(8) == 9);
    CHECK(FN(None,"Open_ReportDevice")() == 11);
    CHECK(FN(None,"Close_ReportDevice")() == 12);
    CHECK(FN(None,"Open_FeatureDevice")() == 13);
    CHECK(FN(None,"Close_FeatureDevice")() == 14);
    CHECK(FN(Monitor,"Open_DevMonitor")((void *)123) == 15);
    CHECK(FN(None,"Close_DevMonitor")() == 16);
    bytes[64] = 0xAB;
    CHECK(FN(Buffer,"WriteUSB")(bytes,65) == 23);
    CHECK(bytes[0] == 4 && bytes[64] == 0xAB);
    CHECK(FN(Buffer,"SetFeature")(bytes,65) == 25);
    CHECK(FN(Buffer,"ReadUSB")(bytes,65) == 24 && bytes[0] == 3 && bytes[64] == 0xCD);
    CHECK(FN(Buffer,"GetFeature")(bytes,65) == 66 && bytes[0] == 0xEF);
    FILE *file = fopen("proxy-test.log", "r");
    CHECK(file != NULL);
    size_t count = fread(log,1,sizeof(log)-1,file); log[count] = 0; fclose(file);
    CHECK(strstr(log,"TX[65]: 04") != NULL);
    CHECK(strstr(log," AB\n") != NULL);
    CHECK(strstr(log," CD\n") != NULL);
    CHECK(strstr(log,"WriteUSB => 23") != NULL);
    puts("PASS: all 12 exports forward arguments/results and log every byte of 65-byte reports");
    return 0;
}
