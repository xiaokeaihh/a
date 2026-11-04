@echo off
chcp 65001 >nul
cd /d "%~dp0"
if defined FPGA_CONTROL_PYTHON (
 "%FPGA_CONTROL_PYTHON%" -B contest_tools\contest_portable.py serve %*
 goto done
)
if exist "D:\fpgapango\person_follow_20261014\runtime\Scripts\python.exe" (
 "D:\fpgapango\person_follow_20261014\runtime\Scripts\python.exe" -B contest_tools\contest_portable.py serve %*
 goto done
)
where py >nul 2>nul
if not errorlevel 1 (
 py -3 -B contest_tools\contest_portable.py serve %*
 goto done
)
python -B contest_tools\contest_portable.py serve %*
:done
pause
