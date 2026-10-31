@echo off
rem Double-click to run the real-content benchmark on the clips in <repo>\media
rem Extra options: run-media.bat -Quick   |   -Filter "*hdr*"   |   -Variants cpu,hyb   |   -NoConcurrency
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0media-test.ps1" %*
echo.
pause
