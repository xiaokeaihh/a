$ErrorActionPreference='Stop'
$taskSimBin='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
Push-Location $PSScriptRoot\..
try {
 & 'D:\python prince\python.exe' -X utf8 -B stabilization_tools\extract_exposure_netlist.py *> verification_stabilization\extract_exposure_net.log
 if($LASTEXITCODE -ne 0){throw 'Sensor ROM extraction failed'}
 if(!(Test-Path -LiteralPath verification_net_exposure)){& "$taskSimBin\vlib.exe" verification_net_exposure | Out-Null}
 $taskCells=Get-Content verification_stabilization\exposure_net_cells.json -Raw | ConvertFrom-Json
 & "$taskSimBin\vlog.exe" -sv -work verification_net_exposure $taskCells verification_stabilization\actual_exposure_rom.v verification_stabilization\tb_exposure_net.sv *> verification_stabilization\exposure_net_compile.log
 if($LASTEXITCODE -ne 0){throw 'Sensor ROM verification compilation failed'}
 & "$taskSimBin\vsim.exe" -c -lib verification_net_exposure tb_exposure_net -l verification_stabilization\exposure_net.log -do 'run -all; quit -f' *> verification_stabilization\exposure_net.console.log
 $taskLog=Get-Content verification_stabilization\exposure_net.log -Raw
 if($taskLog -notmatch 'PASS actual synthesized sensor ROM' -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw 'Actual synthesized sensor ROM check failed'}
 'PASS exposure in the actual synthesized sensor ROM'
} finally {Pop-Location}
