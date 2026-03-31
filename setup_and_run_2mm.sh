#!/usr/bin/env bash
# setup_and_run_2mm.sh
#
# Steps B–E for the full 2mm ModelArray run.
# Run this AFTER 0_register_acpc_to_mni.sh -s 02 has completed.
#
# Usage — all configured modalities:
#   bash setup_and_run_2mm.sh
#
# Usage — one or more specific modalities:
#   bash setup_and_run_2mm.sh od_dwimap
#   bash setup_and_run_2mm.sh icvf_dwimap od_dwimap isovf_dwimap
#
# Usage (detached):
#   nohup bash setup_and_run_2mm.sh > /data/local/134_AF19/derivatives/modelarray/noddi_2mm/setup_run.log 2>&1 &
#
# Each modality needs a matching config file at:
#   configs/config_noddi_<modality>_gam_2mm.json
# Modalities without a config are skipped with a warning.

set -euo pipefail

MODELARRAY_DIR="/data/local/134_AF19/derivatives/modelarray"
NODDI2MM="$MODELARRAY_DIR/noddi_2mm"
PARTICIPANTS="$MODELARRAY_DIR/participants_longitudinal.tsv"
TEMPLATEFLOW="/data/local/templateflow"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Modalities to process ──────────────────────────────────────────────────────
# Pass modality names as arguments, or list them all here as the default.
if [[ $# -gt 0 ]]; then
  MODALITIES=("$@")
else
  MODALITIES=(
    icvf_dwimap
    od_dwimap
    isovf_dwimap
    # Add further modalities here as you create their config files:
    # direction_dwimap
    # tf_dwimap
  )
fi

ts() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Step B: masks directory + group mask (once, shared across modalities) ──────
ts "Step B: creating masks dir and copying 2mm brain mask..."
mkdir -p "$NODDI2MM/masks"
cp "$TEMPLATEFLOW/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-02_desc-brain_mask.nii.gz" \
   "$NODDI2MM/masks/group_mask.nii.gz"
# Also put it at the root (3_run_model.sh looks there)
cp "$NODDI2MM/masks/group_mask.nii.gz" "$NODDI2MM/group_mask.nii.gz"
ts "  done — $(fslstats "$NODDI2MM/masks/group_mask.nii.gz" -V | awk '{print $1}') nonzero voxels"

# ── Steps C–E: repeated for each modality ─────────────────────────────────────
for MODALITY in "${MODALITIES[@]}"; do
  ts "══════════════════════════════════════════════"
  ts "Processing modality: $MODALITY"
  ts "══════════════════════════════════════════════"

  CONFIG="$SCRIPT_DIR/configs/config_noddi_${MODALITY}_gam_2mm.json"
  if [[ ! -f "$CONFIG" ]]; then
    ts "  SKIP — no config found at: $CONFIG"
    continue
  fi

  # Step C: cohort CSV
  ts "  Step C: generating cohort CSV..."
  bash "$SCRIPT_DIR/1_generate_cohort_longitudinal.sh" \
    -p "$PARTICIPANTS" \
    -d "$NODDI2MM/$MODALITY" \
    -m "$NODDI2MM/masks" \
    -o "$NODDI2MM"
  CSV="$NODDI2MM/cohort_${MODALITY}.csv"
  ts "    done — $(tail -n +2 "$CSV" | wc -l) rows in $CSV"

  # Step D: convoxel → HDF5
  ts "  Step D: running convoxel (building HDF5)..."
  bash "$SCRIPT_DIR/2_run_convoxel.sh" \
    -c "$CSV"
  ts "    done — HDF5: $NODDI2MM/cohort_${MODALITY}.h5"

  # Step E: model (GAM)
  ts "  Step E: running ModelArray GAM..."
  bash "$SCRIPT_DIR/3_run_model.sh" "$CONFIG"
  ts "    done — see results in $NODDI2MM/results/"

done

ts "ALL DONE."
