#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: run.sh <input_dir> <platform_dir> <output_dir> <top_module>" >&2
    exit 2
fi

input_dir="$(cd -- "$1" && pwd)"
platform_dir="$(cd -- "$2" && pwd)"
mkdir -p -- "$3"
output_dir="$(cd -- "$3" && pwd)"
top_module="$4"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export INPUT_DEF="${INPUT_DEF:-$input_dir/input.def}"
export INPUT_VERILOG="${INPUT_VERILOG:-$input_dir/input.v}"
export OUTPUT_DEF="${OUTPUT_DEF:-$output_dir/$(basename -- "$input_dir").def}"
export OUTPUT_VERILOG="${OUTPUT_VERILOG:-$output_dir/$(basename -- "$input_dir").v}"
export PLATFORM_DIR="$platform_dir"
export TOP_MODULE="$top_module"
export OPENROAD_EXE="${OPENROAD_EXE:-openroad}"

export NUM_CORES="${NUM_CORES:-8}"
export MCMM_CONFIG="${MCMM_CONFIG:-$input_dir/mcmm.tcl}"
export MAX_VT_TRIALS="${MAX_VT_TRIALS:-8}"
export VT_STRATEGY="${VT_STRATEGY:-batch}"
export VT_ORDER="${VT_ORDER:-sensitivity}"
export VT_TARGET="${VT_TARGET:-SL}"
export VT_BATCH_SIZE="${VT_BATCH_SIZE:-64}"
export MAX_BATCH_CELLS="${MAX_BATCH_CELLS:-512}"
export MAX_HOLD_BUFFERS="${MAX_HOLD_BUFFERS:-1024}"
export VT_PATH_COUNT="${VT_PATH_COUNT:-500}"
export VT_REFRESH_BATCHES="${VT_REFRESH_BATCHES:-2}"
if ! command -v "$OPENROAD_EXE" >/dev/null 2>&1; then
    echo "OpenROAD executable not found: $OPENROAD_EXE. Use the contest container or set OPENROAD_EXE." >&2
    exit 127
fi
if [[ ! "$NUM_CORES" =~ ^[1-9][0-9]*$ ]]; then
    echo "NUM_CORES must be a positive integer." >&2
    exit 2
fi
if [[ ! "$MAX_VT_TRIALS" =~ ^[1-9][0-9]*$ ]]; then
    echo "MAX_VT_TRIALS must be a positive integer." >&2
    exit 2
fi
if [[ ! "$MAX_HOLD_BUFFERS" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "MAX_HOLD_BUFFERS must be a nonnegative integer." >&2
    exit 2
fi
if [[ ! "$VT_STRATEGY" =~ ^(serial|batch)$ || ! "$VT_ORDER" =~ ^(timing|fanout|sensitivity)$ || ! "$VT_TARGET" =~ ^(L|SL)$ ]]; then
    echo "Use VT_STRATEGY=serial|batch, VT_ORDER=timing|fanout|sensitivity, VT_TARGET=L|SL." >&2
    exit 2
fi
if [[ ! "$VT_REFRESH_BATCHES" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "VT_REFRESH_BATCHES must be a nonnegative integer." >&2
    exit 2
fi
for setting in VT_BATCH_SIZE MAX_BATCH_CELLS VT_PATH_COUNT; do
    if [[ ! "${!setting}" =~ ^[1-9][0-9]*$ ]]; then
        echo "$setting must be a positive integer." >&2
        exit 2
    fi
done
for input in "$INPUT_DEF" "$INPUT_VERILOG" "$MCMM_CONFIG"; do
    if [[ ! -r "$input" ]]; then
        echo "Input file is not readable: $input" >&2
        exit 2
    fi
done

exec "$OPENROAD_EXE" -no_init -no_splash -exit "$script_dir/optimizer.tcl"
