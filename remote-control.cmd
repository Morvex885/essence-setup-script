@echo off
wsl -e bash -c "cd \"$(wslpath '%~dp0')\" && bash remote-control/remote-control-essence.sh"
