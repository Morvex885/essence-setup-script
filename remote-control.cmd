@echo off
wsl -e bash -c "cd \"$(wslpath '%~dp0')\" && exec bash remote-control/remote-control-essence.sh \"$@\"" remote-control %*
set "exit_code=%errorlevel%"
if "%~1"=="" if not "%exit_code%"=="0" (
    echo.
    pause
)
exit /b %exit_code%
