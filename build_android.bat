@echo off
chcp 65001 >nul
REM --- Auto-detect Flutter / Dart / Rust / Android NDK ---
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

REM --- Android NDK detection (prefer Android Studio default location) ---
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
if defined ANDROID_NDK_HOME (
  set "PATH=%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin;%PATH%"
  set "CC=aarch64-linux-android24-clang.cmd"
  set "CXX=aarch64-linux-android24-clang++.cmd"
  REM NDK r26+ ships llvm-ar.exe / llvm-ranlib.exe; the old llvm-ar.cmd no longer exists
  set "AR=llvm-ar.exe"
  set "RANLIB=llvm-ranlib.exe"
  REM cargo needs an explicit linker for the aarch64-linux-android target
  set "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=%ANDROID_NDK_HOME%\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android24-clang.cmd"
)

setlocal enabledelayedexpansion
cd /d "%~dp0"
echo === YuChuan Android Build ===
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
echo [2/3] Ensure Rust target aarch64-linux-android...
cargo target list --installed 2>nul | findstr /c:"aarch64-linux-android" >nul
if errorlevel 1 rustup target add aarch64-linux-android
cargo build --manifest-path rust_builder\Cargo.toml --target aarch64-linux-android 2>&1
if errorlevel 1 goto :err
echo [3/3] Flutter build APK...
call "%FLUTTER_BIN%" build apk 2>&1
if errorlevel 1 goto :err
echo Android APK build done.
goto :pause_exit
:err
echo.
echo *** Build failed, see errors above ***
:pause_exit
echo.
echo Press any key to close...
pause >nul
