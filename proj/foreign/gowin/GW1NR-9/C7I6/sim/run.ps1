#
# Simulate the host bus interfaces with iverilog.
#
#   .\run.ps1           both testbenches
#   .\run.ps1 bus       write only interface
#   .\run.ps1 busV2     write and read interface
#
param([string]$Target = "all")

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# iverilog ships with msys64 and is usually not on the system PATH
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) {
    $msys = "C:\msys64\ucrt64\bin"
    if (Test-Path "$msys\iverilog.exe") {
        $env:Path = "$msys;$env:Path"
    } else {
        throw "iverilog not found. Install Icarus Verilog or add its bin folder to PATH."
    }
}

$sv  = "../systemverilog"
$out = "output"
if (-not (Test-Path $out)) { New-Item -ItemType Directory $out | Out-Null }

function Invoke-Sim {
    param([string]$Name, [string[]]$Sources)

    Write-Host "### $Name ###"
    iverilog -g2012 -o "$out/$Name.vvp" @Sources
    if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $Name" }
    vvp "$out/$Name.vvp"
    if ($LASTEXITCODE -ne 0) { throw "vvp failed for $Name" }
}

$busSources   = @("tb_bus.sv",   "$sv/bus.sv",   "$sv/dff_sync.sv")
$busV2Sources = @("tb_busV2.sv", "$sv/busV2.sv", "$sv/sync_edge.sv", "$sv/dff_sync.sv")

switch ($Target) {
    "bus"   { Invoke-Sim "tb_bus"   $busSources }
    "busV2" { Invoke-Sim "tb_busV2" $busV2Sources }
    "all"   { Invoke-Sim "tb_bus" $busSources; Write-Host ""; Invoke-Sim "tb_busV2" $busV2Sources }
    default { Write-Error "usage: .\run.ps1 [bus|busV2]" }
}
