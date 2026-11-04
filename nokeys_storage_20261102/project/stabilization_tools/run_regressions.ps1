$ErrorActionPreference='Stop'
$taskSimBin='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
$taskRtl='source\design_fisheye_5frame_720p60_pipeline\rtl'
Push-Location $PSScriptRoot\..
try {
 if(!(Test-Path -LiteralPath verification_stabilization\_info)){& "$taskSimBin\vlib.exe" verification_stabilization | Out-Null}
 $taskFiles=Get-ChildItem $taskRtl -Filter '*.v' | Where-Object {$_.Name -notin @('fisheye5_imu_top.v','rom_diagnostic.v')} | ForEach-Object {$_.FullName}
 $taskExtra=Get-ChildItem "$taskRtl\fifo_vendor" -Filter '*.v' | ForEach-Object {$_.FullName}
 $taskExtra+=@('source\rtl\wr_cmd_trans.v','source\rtl\wr_ctrl.v','source\rtl\rd_ctrl.v','source\rtl\wr_rd_ctrl_top.v')
 $taskExtra+='ipcore\wr_fram_buf\rtl\ipm2l_sdpram_v1_10_wr_fram_buf.v'
 $taskExtra+='D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM18K.v'
 $taskExtra+='D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_GRS.v'
 $taskExtra+='D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM36K_E1.v'
 $taskTests=@('verification_stabilization\tb_projection.sv','verification_stabilization\tb_pose_protocol.sv','verification_stabilization\tb_pose_store.sv',
  'verification_quality\tb_baseline_keys.sv','verification_quality\tb_baseline_gamma_osd.sv',
  'verification_quality\tb_baseline_display.sv','verification_quality\tb_capture_vendor.sv',
  'verification_quality\tb_quality_frames.sv','verification_quality\tb_quality_control.sv')
 & "$taskSimBin\vlog.exe" -sv -work verification_stabilization $taskFiles $taskExtra $taskTests *> verification_stabilization\regression_compile.log
 if($LASTEXITCODE -ne 0){throw 'simulation compilation failed'}
 foreach($taskTop in @('tb_projection','tb_pose_protocol','tb_pose_store','tb_baseline_keys','tb_baseline_gamma_osd','tb_baseline_display','tb_capture_vendor','tb_quality_control')){
  & "$taskSimBin\vsim.exe" -c -lib verification_stabilization $taskTop -l "verification_stabilization\$taskTop.log" -do 'run -all; quit -f' *> "verification_stabilization\$taskTop.console.log"
  $taskLog=Get-Content "verification_stabilization\$taskTop.log" -Raw
  if($taskLog -notmatch 'PASS ' -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw "regression failed: $taskTop"}
  Write-Output "PASS $taskTop"
 }
} finally {Pop-Location}
