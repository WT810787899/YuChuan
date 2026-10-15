@echo off
chcp 65001 >nul
REM --- Auto-detect Flutter / Dart / Rust ---
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

cd /d "%~dp0"
title YuChuan Windows Run
if not defined FLUTTER_BIN (
  echo ERROR: Flutter not found. Install Flutter or set FLUTTER_ROOT.
  goto :err
)
echo === YuChuan Windows Run ===
echo.
REM Pin the Windows desktop device: with a phone connected, flutter would pick it instead
call "%FLUTTER_BIN%" run -d windows 2>&1
if errorlevel 1 goto :err
goto :pause_exit
:err
echo.
echo *** Run failed, see errors above ***
:pause_exit
echo.
echo Press any key to close...
pause >nul
