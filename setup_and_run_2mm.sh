#!/usr/bin/env bash
# setup_and_run_2mm.sh
#
# Steps B–E for the full 2mm ModelArray run.
# Run this AFTER 0_register_acpc_to_mni.sh -s 02 has completed.
#
# Usage (foreground):  bash setup_and_run_2mm.sh
# Usage (detached):    nohup bash setup_and_run_2mm.sh > /data/local/134_AF19/derivatives/modelarray/noddi_2mm/setup_run.log 2>&1 &

set -euo pipefail

MODELARRAY_DIR="/data/local/134_AF19/derivatives/modelarray"
NODDI2MM="$MODELARRAY_DIR/noddi_2mm"
PARTICIPANTS="$MODELARRAY_DIR/participants_longitudinal.tsv"
TEMPLATEFLOW="/data/local/templateflow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Step B: masks directory + group mask ──────────────────────────────────────
ts "Step B: creating masks dir and copying 2mm brain mask..."
mkdir -p "$NODDI2MM/masks"
cp "$TEMPLATEFLOW/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-02_desc-brain_mask.nii.gz" \
   "$NODDI2MM/masks/group_mask.nii.gz"
# Also put it at the root (3_run_model.sh looks there)
cp "$NODDI2MM/masks/group_mask.nii.gz" "$NODDI2MM/group_mask.nii.gz"
ts "  done — $(fslstats "$NODDI2MM/masks/group_mask.nii.gz" -V | awk '{print $1}') nonzero voxels"

# ── Step C: cohort CSV ────────────────────────────────────────────────────────
ts "Step C: generating cohort CSV..."
bash "$SCRIPT_DIR/1_generate_cohort_longitudinal.sh" \
  -p "$PARTICIPANTS" \
  -d "$NODDI2MM/icvf_dwimap" \
  -m "$NODDI2MM/masks" \
  -o "$NODDI2MM"
CSV="$NODDI2MM/cohort_icvf_dwimap.csv"
ts "  done — $(tail -n +2 "$CSV" | wc -l) rows in $CSV"

# ── Step D: convoxel → HDF5 ────────────────────────────────────────────────────
ts "Step D: running convoxel (building HDF5)..."
bash "$SCRIPT_DIR/2_run_convoxel.sh" \
  -c "$CSV" \
  -r "$NODDI2MM"
ts "  done — HDF5: $NODDI2MM/cohort_icvf_dwimap.h5"

# ── Step E: model (GAM) ───────────────────────────────────────────────────────
ts "Step E: running ModelArray GAM — full 2mm..."
bash "$SCRIPT_DIR/3_run_model.sh" \
  "$SCRIPT_DIR/configs/config_noddi_icvf_gam_2mm.json"

ts "ALL DONE. Results in $NODDI2MM/results/icvf_gam_2mm/"
