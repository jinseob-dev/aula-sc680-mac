@echo off
setlocal
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call "%%i\VC\Auxiliary\Build\vcvarsall.bat" x86
if errorlevel 1 exit /b 1
if not exist tools\capture-build mkdir tools\capture-build
cl /nologo /O2 /W4 /std:c11 /D_CRT_SECURE_NO_WARNINGS /LD tools\hid_proxy\hiddriver_8k_proxy.c /Fe:tools\capture-build\hiddriver_8k.dll /Fo:tools\capture-build\proxy.obj /link /DEF:tools\hid_proxy\hiddriver_8k.def
if errorlevel 1 exit /b 1
cl /nologo /O2 /W4 /std:c11 /D_CRT_SECURE_NO_WARNINGS /LD tools\hid_proxy\tests\fake_driver.c /Fe:tools\capture-build\hiddriver_8k_orig.dll /Fo:tools\capture-build\fake.obj /link /DEF:tools\hid_proxy\hiddriver_8k.def
if errorlevel 1 exit /b 1
cl /nologo /O2 /W4 /std:c11 /D_CRT_SECURE_NO_WARNINGS tools\hid_proxy\tests\test_proxy.c /Fe:tools\capture-build\test_proxy.exe /Fo:tools\capture-build\test.obj
if errorlevel 1 exit /b 1
pushd tools\capture-build
test_proxy.exe
set test_result=%errorlevel%
popd
exit /b %test_result%
