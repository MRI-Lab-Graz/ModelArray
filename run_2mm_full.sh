#!/usr/bin/env bash
# run_2mm_full.sh
#
# Step A: finish 2mm registration (skips already-done files)
# Then launches Steps B-E (mask, cohort, convoxel, model) as a detached nohup job.
#
# Usage:  bash run_2mm_full.sh

set -euo pipefail

cd /data/local/software/ModelArray

LOGFILE="/data/local/134_AF19/derivatives/modelarray/noddi_2mm/setup_run.log"

echo "========================================"
echo "  Step A: finishing 2mm registration"
echo "========================================"

bash 0_register_acpc_to_mni.sh \
  -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI \
  -s 02 \
  -m /data/local/134_AF19/derivatives/modelarray/noddi_2mm \
  -j 8

echo ""
echo "========================================"
echo "  Step A done. Launching B-E in background."
echo "  Log: $LOGFILE"
echo "========================================"

nohup bash setup_and_run_2mm.sh > "$LOGFILE" 2>&1 &
echo "PID: $!"
echo ""
echo "Monitor with:"
echo "  tail -f $LOGFILE"
