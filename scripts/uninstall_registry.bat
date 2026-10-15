@echo off
rem ====================================================================
rem  YuChuan - clean Explorer context menu registry entries
rem
rem  Removes the per-user (HKCU) keys added by
rem  scripts\explorer_context_menu.ps1 -Install
rem
rem  HKCU needs NO admin rights, so this works for any standard user
rem  and touches nothing belonging to other accounts or the machine.
rem ====================================================================

echo.
echo Removing YuChuan Explorer context menu entries...

reg delete "HKCU\Software\Classes\*\shell\YuChuan.Send" /f >nul 2>&1
if %errorlevel%==0 (echo   removed: file context menu) else (echo   not present: file context menu)

reg delete "HKCU\Software\Classes\Directory\shell\YuChuan.Send" /f >nul 2>&1
if %errorlevel%==0 (echo   removed: folder context menu) else (echo   not present: folder context menu)

echo.
echo Done. Restart Explorer or press F5 in a window to refresh.
echo.
pause
