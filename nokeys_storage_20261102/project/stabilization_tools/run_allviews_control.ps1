$ErrorActionPreference='Stop'
$taskSimBin='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
Push-Location $PSScriptRoot\..
try {
 if(!(Test-Path -LiteralPath verification_control_allviews)){& "$taskSimBin\vlib.exe" verification_control_allviews | Out-Null}
 $taskRtl='source\design_fisheye_5frame_720p60_pipeline\rtl'
 $taskFiles=Get-ChildItem $taskRtl -Filter '*.v' | Where-Object {$_.Name -notin @('fisheye5_imu_top.v','rom_diagnostic.v')} | ForEach-Object {$_.FullName}
 $taskExtra=Get-ChildItem "$taskRtl\fifo_vendor" -Filter '*.v' | ForEach-Object {$_.FullName}
 $taskExtra+=@('source\rtl\wr_cmd_trans.v','source\rtl\wr_ctrl.v','source\rtl\rd_ctrl.v','source\rtl\wr_rd_ctrl_top.v',
  'ipcore\wr_fram_buf\rtl\ipm2l_sdpram_v1_10_wr_fram_buf.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM18K.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_GRS.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM36K_E1.v')
 & "$taskSimBin\vlog.exe" -sv -work verification_control_allviews $taskFiles $taskExtra verification_stabilization\tb_allviews_routes.sv verification_stabilization\tb_telemetry.sv *> verification_stabilization\allviews_control_compile.log
 if($LASTEXITCODE -ne 0){throw 'control simulation compilation failed'}
 foreach($taskTop in @('tb_allviews_routes','tb_telemetry')){
  & "$taskSimBin\vsim.exe" -c -lib verification_control_allviews $taskTop -l "verification_stabilization\$taskTop.log" -do 'run -all; quit -f' *> "verification_stabilization\$taskTop.console.log"
  $taskLog=Get-Content "verification_stabilization\$taskTop.log" -Raw
  if($taskLog -notmatch 'PASS ' -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw "control regression failed: $taskTop"}
 }
 & 'D:\python prince\python.exe' stabilization_tools\check_telemetry.py
 if($LASTEXITCODE -ne 0){throw 'PC telemetry decode failed'}
 Write-Output 'PASS all-view renderer selection and actual UART capability report'
} finally {Pop-Location}
