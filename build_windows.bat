@echo off
chcp 65001 >nul
REM --- Auto-detect Flutter / Dart / Rust ---
if not defined FLUTTER_ROOT (
  for %%d in (C D E F G H) do if exist "%%d:\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%%d:\flutter"
  if not defined FLUTTER_ROOT if exist "%USERPROFILE%\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%USERPROFILE%\flutter"
  if not defined FLUTTER_ROOT if exist "%LOCALAPPDATA%\flutter\bin\flutter.bat" set "FLUTTER_ROOT=%LOCALAPPDATA%\flutter"
)
if defined FLUTTER_ROOT set "FLUTTER_BIN=%FLUTTER_ROOT%\bin\flutter.bat"
REM flutter\bin must be on PATH: flutter_rust_bridge_codegen shells out to "flutter"/"dart"
if defined FLUTTER_ROOT set "PATH=%FLUTTER_ROOT%\bin;%PATH%"

for %%d in (C D E F G H) do if exist "%%d:\.cargo\bin\cargo.exe" set "CARGO_ROOT=%%d:\.cargo"
if not defined CARGO_ROOT if exist "%USERPROFILE%\.cargo\bin\cargo.exe" set "CARGO_ROOT=%USERPROFILE%\.cargo"
if defined CARGO_ROOT set "PATH=%CARGO_ROOT%\bin;%PATH%"

cd /d "%~dp0"
title YuChuan Windows Build
if not defined FLUTTER_BIN (
  echo ERROR: Flutter not found. Install Flutter or set FLUTTER_ROOT.
  goto :err
)
REM flutter_rust_bridge 2.x no longer has "flutter pub run flutter_rust_bridge:release"
where flutter_rust_bridge_codegen >nul 2>&1
if errorlevel 1 (
  echo ERROR: flutter_rust_bridge_codegen not found.
  echo        Install it with: cargo install flutter_rust_bridge_codegen
  echo        ^(the version should match the flutter_rust_bridge version in pubspec.yaml^)
  goto :err
)
echo [1/3] flutter_rust_bridge codegen...
call "%FLUTTER_BIN%" pub get 2>&1
if errorlevel 1 goto :err
flutter_rust_bridge_codegen generate 2>&1
if errorlevel 1 goto :err
echo [2/3] Compile Rust static lib (x86_64-pc-windows-msvc)...
cargo build --manifest-path rust_builder\Cargo.toml --target x86_64-pc-windows-msvc 2>&1
if errorlevel 1 goto :err
echo [3/3] Flutter build...
REM Kill a running instance so MSVC can overwrite the exe (otherwise LINK : fatal error LNK1104)
chcp 65001 >nul 2>&1
taskkill /f /im 雨传.exe >nul 2>&1
taskkill /f /im rust_flutter_ui.exe >nul 2>&1
call "%FLUTTER_BIN%" build windows 2>&1
if errorlevel 1 goto :err
echo Windows build done.
goto :pause_exit
:err
echo.
echo *** Build failed, see errors above ***
:pause_exit
echo.
echo Press any key to close...
pause >nul
