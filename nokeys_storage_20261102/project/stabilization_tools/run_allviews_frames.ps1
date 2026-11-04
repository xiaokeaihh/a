$ErrorActionPreference='Stop'
$taskSimBin='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
Push-Location $PSScriptRoot\..
try {
 if(!(Test-Path -LiteralPath verification_stabilization\allviews_gold_0.mem)){
  & 'D:\python prince\python.exe' stabilization_tools\generate_frame_gold.py
  if($LASTEXITCODE -ne 0){throw 'pixel reference generation failed'}
 }
 if(!(Test-Path -LiteralPath verification_allviews)){& "$taskSimBin\vlib.exe" verification_allviews | Out-Null}
 $taskRtl='source\design_fisheye_5frame_720p60_pipeline\rtl'
 $taskFiles=Get-ChildItem $taskRtl -Filter '*.v' | Where-Object {$_.Name -notin @('fisheye5_imu_top.v','rom_diagnostic.v')} | ForEach-Object {$_.FullName}
 $taskExtra=Get-ChildItem "$taskRtl\fifo_vendor" -Filter '*.v' | ForEach-Object {$_.FullName}
 $taskExtra+=@('source\rtl\wr_cmd_trans.v','source\rtl\wr_ctrl.v','source\rtl\rd_ctrl.v','source\rtl\wr_rd_ctrl_top.v',
  'ipcore\wr_fram_buf\rtl\ipm2l_sdpram_v1_10_wr_fram_buf.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM18K.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_GRS.v',
  'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation\GTP_DRM36K_E1.v')
 & "$taskSimBin\vlog.exe" -sv -work verification_allviews $taskFiles $taskExtra verification_stabilization\tb_allviews_frames.sv *> verification_stabilization\allviews_frames_compile.log
 if($LASTEXITCODE -ne 0){throw 'all-view frame simulation compilation failed'}
 & "$taskSimBin\vsim.exe" -c -lib verification_allviews tb_allviews_frames -l verification_stabilization\allviews_frames.log -do 'run -all; quit -f' *> verification_stabilization\allviews_frames.console.log
 $taskLog=Get-Content verification_stabilization\allviews_frames.log -Raw
 if(($taskLog | Select-String 'PASS all-view case' -AllMatches).Matches.Count -ne 14 -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw 'all-view pixel regression failed'}
 Write-Output 'PASS 14 all-view full-frame pixel checks'
} finally {Pop-Location}
