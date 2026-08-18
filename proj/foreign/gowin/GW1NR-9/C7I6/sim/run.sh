#!/usr/bin/env bash
#
# Simulate the host bus interfaces with iverilog.
#
#   ./run.sh          both testbenches
#   ./run.sh bus      write only interface
#   ./run.sh busV2    write and read interface
#
set -e
cd "$(dirname "$0")"

sv=../systemverilog
out=output
mkdir -p "$out"

run_bus() {
    echo "### tb_bus, write only interface ###"
    iverilog -g2012 -o "$out/tb_bus.vvp" tb_bus.sv $sv/bus.sv $sv/dff_sync.sv
    vvp "$out/tb_bus.vvp"
}

run_busV2() {
    echo "### tb_busV2, write and read interface ###"
    iverilog -g2012 -o "$out/tb_busV2.vvp" tb_busV2.sv $sv/busV2.sv $sv/sync_edge.sv $sv/dff_sync.sv
    vvp "$out/tb_busV2.vvp"
}

case "${1:-all}" in
    bus)   run_bus ;;
    busV2) run_busV2 ;;
    all)   run_bus; echo; run_busV2 ;;
    *)     echo "usage: $0 [bus|busV2]" >&2; exit 1 ;;
esac
