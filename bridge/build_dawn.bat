@echo off
setlocal EnableExtensions
rem Build the x64 Dawn bridge without replacing a working DLL on failure.


set "BRIDGE_DIR=%~dp0"

rem DAWN_DIR must point to the root of a Dawn source/build tree.
if not defined DAWN_DIR (
  echo [error] DAWN_DIR is not set.
  echo [error] Set DAWN_DIR to the Dawn root directory and run this batch file again.
  exit /b 1
)

rem Require the selected Visual Studio developer environment and x64 tools.
if not defined VSINSTALLDIR (
  echo [error] This is not a Visual Studio 2026 Developer Command Prompt.
  echo [error] Open that prompt and run this batch file again.
  exit /b 1
)

if /I not "%VSCMD_ARG_TGT_ARCH%"=="x64" (
  if not exist "%VSINSTALLDIR%VC\Auxiliary\Build\vcvarsall.bat" (
    echo [error] vcvarsall.bat was not found under VSINSTALLDIR.
    exit /b 1
  )

  call "%VSINSTALLDIR%VC\Auxiliary\Build\vcvarsall.bat" x64 >nul
  if errorlevel 1 (
    echo [error] Failed to switch the Visual Studio 2026 tools to x64.
    exit /b 1
  )
)

if /I not "%VSCMD_ARG_TGT_ARCH%"=="x64" (
  echo [error] MSVC target is not x64.
  echo [error] VSCMD_ARG_TGT_ARCH=%VSCMD_ARG_TGT_ARCH%
  exit /b 1
)

where cl.exe >nul 2>nul
if errorlevel 1 (
  echo [error] cl.exe was not found.
  exit /b 1
)

where link.exe >nul 2>nul
if errorlevel 1 (
  echo [error] link.exe was not found.
  exit /b 1
)

echo [info] Visual Studio: %VisualStudioVersion%
echo [info] MSVC target: %VSCMD_ARG_TGT_ARCH%

rem Resolve and validate every compiler, linker, and runtime input.
set "DAWN_INC=%DAWN_DIR%\out\Release-msvc\gen\include"
set "DAWN_LIB=%DAWN_DIR%\out\Release-msvc\src\dawn\native\webgpu_dawn.lib"
set "DAWN_DLL=%DAWN_DIR%\out\Release-msvc\webgpu_dawn.dll"

if not exist "%BRIDGE_DIR%bridge_dawn.c" (
  echo [error] Missing bridge_dawn.c.
  exit /b 1
)
if not exist "%DAWN_INC%\dawn\webgpu.h" (
  echo [error] Missing Dawn header: "%DAWN_INC%\dawn\webgpu.h"
  exit /b 1
)
if not exist "%DAWN_LIB%" (
  echo [error] Missing Dawn library: "%DAWN_LIB%"
  exit /b 1
)
if not exist "%DAWN_DLL%" (
  echo [error] Missing Dawn DLL: "%DAWN_DLL%"
  exit /b 1
)

echo [info] Dawn: "%DAWN_DIR%"

rem Build a temporary DLL, verify its machine type, then replace the current DLL.
pushd "%BRIDGE_DIR%"
if errorlevel 1 (
  echo [error] Could not enter the bridge directory.
  exit /b 1
)

del /q bridge_dawn.obj 2>nul
del /q bridge_dawn.lib 2>nul
del /q bridge_dawn.exp 2>nul
del /q bridge_dawn.new.dll 2>nul

cl.exe /nologo /utf-8 /O2 /W3 /MD /TC /LD /I"%DAWN_INC%" /Fobridge_dawn.obj /Febridge_dawn.new.dll bridge_dawn.c /link /MACHINE:X64 "%DAWN_LIB%"

if errorlevel 1 goto build_failed
if not exist bridge_dawn.new.dll goto output_missing

dumpbin /headers bridge_dawn.new.dll | findstr /c:"8664 machine (x64)" >nul
if errorlevel 1 goto wrong_machine

move /y bridge_dawn.new.dll bridge_dawn.dll >nul
if errorlevel 1 goto replace_failed

popd
echo [ok] "%BRIDGE_DIR%bridge_dawn.dll"
echo [info] The generated DLL is x64.
exit /b 0

:build_failed
popd
echo [error] ###############################################
echo [error] bridge_dawn.dll build failed.
echo [error] The existing bridge_dawn.dll was not replaced.
echo [error] ###############################################
exit /b 1

:output_missing
popd
echo [error] ###############################################
echo [error] bridge_dawn.new.dll was not created.
echo [error] ###############################################
exit /b 1

:wrong_machine
popd
echo [error] ###############################################
echo [error] The generated DLL is not x64.
echo [error] The existing bridge_dawn.dll was not replaced.
echo [error] ###############################################
exit /b 1

:replace_failed
popd
echo [error] ###############################################
echo [error] Failed to replace bridge_dawn.dll.
echo [error] ###############################################
exit /b 1

