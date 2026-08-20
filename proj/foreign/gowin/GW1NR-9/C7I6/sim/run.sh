#!/usr/bin/env bash
#
# Simulate the host bus interfaces with iverilog.
#
#   ./run.sh          all testbenches
#   ./run.sh bus       write only interface
#   ./run.sh busV2     write and read interface
#   ./run.sh busV3     double data rate interface
#   ./run.sh watch     busV2 + cpu_watch, as top.sv wires them
#
set -e
cd "$(dirname "$0")"

sv=../systemverilog
out=output
mkdir -p "$out"

run_bus() {
    echo "### tb_bus, write only interface ###"
    iverilog -g2012 -o "$out/tb_bus.vvp" tb_bus.sv $sv/bus.sv $sv/bs_dff_sync.sv
    vvp "$out/tb_bus.vvp"
}

run_busV2() {
    echo "### tb_busV2, write and read interface ###"
    iverilog -g2012 -o "$out/tb_busV2.vvp" tb_busV2.sv $sv/busV2.sv $sv/sync_edge.sv $sv/bs_dff_sync.sv
    vvp "$out/tb_busV2.vvp"
}

run_busV3() {
    echo "### tb_busV3_ddr, double data rate interface ###"
    iverilog -g2012 -o "$out/tb_busV3_ddr.vvp" tb_busV3_ddr.sv $sv/busV3_ddr.sv $sv/sync_edge.sv $sv/bs_dff_sync.sv
    vvp "$out/tb_busV3_ddr.vvp"
}

run_watch() {
    echo "### tb_cpu_watch, busV2 + cpu_watch as top.sv wires them ###"
    iverilog -g2012 -o "$out/tb_cpu_watch.vvp" tb_cpu_watch.sv $sv/busV2.sv $sv/cpu_watch.sv $sv/sync_edge.sv $sv/bs_dff_sync.sv
    vvp "$out/tb_cpu_watch.vvp"
}

case "${1:-all}" in
    bus)   run_bus ;;
    busV2) run_busV2 ;;
    busV3) run_busV3 ;;
    watch) run_watch ;;
    all)   run_bus; echo; run_busV2; echo; run_busV3; echo; run_watch ;;
    *)     echo "usage: $0 [bus|busV2|busV3|watch]" >&2; exit 1 ;;
esac
