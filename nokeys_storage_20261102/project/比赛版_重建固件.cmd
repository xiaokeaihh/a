@echo off
chcp 65001 >nul
cd /d "%~dp0"
if defined FPGA_CONTROL_PYTHON if exist "%FPGA_CONTROL_PYTHON%" (
 "%FPGA_CONTROL_PYTHON%" -B contest_tools\contest_portable.py build %*
 goto done
)
where py >nul 2>nul
if not errorlevel 1 (
 py -3 -B contest_tools\contest_portable.py build %*
 goto done
)
where python >nul 2>nul
if not errorlevel 1 (
 python -B contest_tools\contest_portable.py build %*
 goto done
)
if exist "D:\fpgapango\person_follow_20261014\runtime\Scripts\python.exe" (
 "D:\fpgapango\person_follow_20261014\runtime\Scripts\python.exe" -B contest_tools\contest_portable.py build %*
 goto done
)
echo 请先安装 Python 3，或设置 FPGA_CONTROL_PYTHON 指向 python.exe。
:done
pause
