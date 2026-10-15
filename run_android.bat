@echo off
chcp 65001 >nul
REM --- Auto-detect Flutter / Dart / Rust / Android NDK ---
if not defined FLUTTER_ROOT (
  for %%d in (C D E F G H) do if exist "%%d:\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%%d:\flutter"
  if not defined FLUTTER_ROOT if exist "%USERPROFILE%\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%USERPROFILE%\flutter"
  if not defined FLUTTER_ROOT if exist "%LOCALAPPDATA%\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%LOCALAPPDATA%\flutter"
)
if defined FLUTTER_ROOT set "FLUTTER_BIN=%FLUTTER_ROOT%\bin\flutter.bat"
if defined FLUTTER_ROOT set "PATH=%FLUTTER_ROOT%\bin;%PATH%"

for %%d in (C D E F G H) do if exist "%%d:\.cargo\bin\cargo.exe" set "CARGO_ROOT=%%d:\.cargo"
if not defined CARGO_ROOT if exist "%USERPROFILE%\.cargo\bin\cargo.exe" set "CARGO_ROOT=%USERPROFILE%\.cargo"
if defined CARGO_ROOT set "PATH=%CARGO_ROOT%\bin;%PATH%"

REM --- Android NDK detection (only export ANDROID_NDK_HOME; do NOT put NDK tools on PATH
REM     and do NOT set CC/AR globally - that breaks host (Windows) builds, see run log) ---
if not defined ANDROID_NDK_HOME (
  for %%d in (C D E F G H) do (
    if exist "%%d:\Users\%USERNAME%\AppData\Local\Android\Sdk\ndk" (
      for /f "delims=" %%v in ('dir /b /o:-n "%%d:\Users\%USERNAME%\AppData\Local\Android\Sdk\ndk" 2^>nul') do (
        if not defined ANDROID_NDK_HOME set "ANDROID_NDK_HOME=%%d:\Users\%USERNAME%\AppData\Local\Android\Sdk\ndk\%%v"
      )
    )
    if exist "%%d:\Android\Sdk\ndk" (
      for /f "delims=" %%v in ('dir /b /o:-n "%%d:\Android\Sdk\ndk" 2^>nul') do (
        if not defined ANDROID_NDK_HOME set "ANDROID_NDK_HOME=%%d:\Android\Sdk\ndk\%%v"
      )
    )
  )
)

setlocal enabledelayedexpansion
cd /d "%~dp0"
title YuChuan Android Run
if not defined FLUTTER_BIN (
  echo ERROR: Flutter not found. Install Flutter or set FLUTTER_ROOT.
  goto :err
)
echo === YuChuan Android Run ===
echo.
REM Without an Android device flutter silently falls back to the Windows desktop
call "%FLUTTER_BIN%" devices 2>nul | findstr /i /c:"android" >nul
if errorlevel 1 (
  echo ERROR: No Android device connected. Connect a device or start an emulator first.
  goto :err
)
call "%FLUTTER_BIN%" run 2>&1
if errorlevel 1 goto :err
goto :pause_exit
:err
echo.
echo *** Run failed, see errors above ***
:pause_exit
echo.
echo Press any key to close...
pause >nul
