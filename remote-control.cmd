@echo off
wsl -e bash -c "cd \"$(wslpath '%~dp0')\" && bash remote-control/remote-control-essence.sh"
set "exit_code=%errorlevel%"
if not "%exit_code%"=="0" (
    echo.
    pause
)
exit /b %exit_code%
