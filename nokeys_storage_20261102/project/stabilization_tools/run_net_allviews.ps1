param([switch]$UseReleasedNetlist)
$ErrorActionPreference='Stop'
$taskSimBin='C:\intelFPGA\18.1\modelsim_ase\win32aloem'
Push-Location $PSScriptRoot\..
try {
 if($UseReleasedNetlist){
  $taskReportPath='allviews_release_report.json'
  $taskHashesPath='verification_stabilization\allviews_source_hashes.json'
  if(Test-Path -LiteralPath unified_release_report.json){
   $taskReportPath='unified_release_report.json'
   $taskHashesPath='verification_stabilization\unified_source_hashes.json'
  }
  $taskRelease=Get-Content -LiteralPath $taskReportPath -Raw | ConvertFrom-Json
  if((Get-FileHash -LiteralPath verification_stabilization\actual_projection_net.v).Hash.ToLower() -ne $taskRelease.actual_projection_net_sha256){throw 'Released netlist hash mismatch'}
  $taskSourceHashes=Get-Content -LiteralPath $taskHashesPath -Raw | ConvertFrom-Json
  foreach($taskEntry in $taskSourceHashes.PSObject.Properties){
   if($taskEntry.Name -match '^source[\\/]'){
    if((Get-FileHash -LiteralPath $taskEntry.Name).Hash.ToLower() -ne $taskEntry.Value){throw "Source differs from released netlist: $($taskEntry.Name)"}
   }
  }
 } else {
  & 'D:\python prince\python.exe' stabilization_tools\extract_projection_netlist.py *> verification_stabilization\extract_allviews_net.log
  if($LASTEXITCODE -ne 0){throw 'netlist extraction failed'}
 }
 if(!(Test-Path -LiteralPath verification_net_allviews)){& "$taskSimBin\vlib.exe" verification_net_allviews | Out-Null}
 $taskCells=Get-Content verification_stabilization\netlist_cells.json -Raw | ConvertFrom-Json
 & "$taskSimBin\vlog.exe" -sv -work verification_net_allviews $taskCells verification_stabilization\actual_projection_net.v verification_stabilization\tb_projection_netlist.sv *> verification_stabilization\net_allviews_compile.log
 if($LASTEXITCODE -ne 0){throw 'netlist simulation compilation failed'}
 & "$taskSimBin\vsim.exe" -c -lib verification_net_allviews tb_projection_netlist -l verification_stabilization\projection_netlist.log -do 'run -all; quit -f' *> verification_stabilization\projection_netlist.console.log
 $taskLog=Get-Content verification_stabilization\projection_netlist.log -Raw
 if($taskLog -notmatch 'PASS actual full-design synthesized projection/ROM, 150 vectors' -or $taskLog -match '\*\* Fatal:' -or $taskLog -notmatch 'Errors: 0'){throw 'synthesized projection regression failed'}
 Write-Output 'PASS actual synthesized projection and four lens ROMs'
} finally {Pop-Location}
