#!/usr/bin/env bash
#
# Simulate the host bus interfaces with iverilog.
#
#   ./run.sh          all testbenches
#   ./run.sh sync      dff_synchroniser and the edge detect
#   ./run.sh busV2     write and read interface
#   ./run.sh watch     busV2 + cpu_watch, as top.sv wires them
#
set -e
cd "$(dirname "$0")"

sv=../systemverilog
out=output
mkdir -p "$out"

run_sync() {
    echo "### tb_dff_synchroniser, synchroniser and edge detect ###"
    iverilog -g2012 -o "$out/tb_dff_synchroniser.vvp" tb_dff_synchroniser.sv $sv/dff_synchroniser.sv
    vvp "$out/tb_dff_synchroniser.vvp"
}

run_busV2() {
    echo "### tb_busV2, write and read interface ###"
    iverilog -g2012 -o "$out/tb_busV2.vvp" tb_busV2.sv $sv/busV2.sv $sv/dff_synchroniser.sv
    vvp "$out/tb_busV2.vvp"
}

run_watch() {
    echo "### tb_cpu_watch, busV2 + cpu_watch as top.sv wires them ###"
    iverilog -g2012 -o "$out/tb_cpu_watch.vvp" tb_cpu_watch.sv $sv/busV2.sv $sv/cpu_watch.sv $sv/dff_synchroniser.sv
    vvp "$out/tb_cpu_watch.vvp"
}

case "${1:-all}" in
    sync)  run_sync ;;
    busV2) run_busV2 ;;
    watch) run_watch ;;
    all)   run_sync; echo; run_busV2; echo; run_watch ;;
    *)     echo "usage: $0 [sync|busV2|watch]" >&2; exit 1 ;;
esac
