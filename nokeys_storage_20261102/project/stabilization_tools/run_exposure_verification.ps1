$ErrorActionPreference='Stop'
$taskSim='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
Push-Location $PSScriptRoot\..
try {
 if(!(Test-Path verification_exposure)){& "$taskSim\vlib.exe" verification_exposure | Out-Null}
 & "$taskSim\vlog.exe" -sv -work verification_exposure source\design_fisheye_5frame_720p60_pipeline\rtl\reg_config_720p.v source\rtl\i2c_com.v verification_stabilization\tb_camera_exposure.sv *> verification_stabilization\exposure_compile.log
 if($LASTEXITCODE -ne 0){throw 'Exposure simulation compilation failed'}
 & "$taskSim\vsim.exe" -c -lib verification_exposure tb_camera_exposure -l verification_stabilization\camera_exposure.log -do 'run -all; quit -f' *> verification_stabilization\camera_exposure.console.log
 $taskLog=Get-Content verification_stabilization\camera_exposure.log -Raw
 if($taskLog -notmatch 'PASS 500-line exposure register bytes' -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw 'Exposure register regression failed'}
 'PASS camera exposure preset and unchanged capture timing'
} finally {Pop-Location}
