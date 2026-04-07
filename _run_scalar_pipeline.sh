#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: _run_scalar_pipeline.sh [--dry-run] [--nohup] /path/to/config.json
       (Prefer using run_analysis.sh as the main entry point)

Runs an end-to-end ModelArray workflow for a SINGLE SCALAR from a JSON config:
  1. Optional ACPC->MNI registration/linking
  2. Group-mask staging
  3. Cohort CSV generation
  4. convoxel HDF5 generation
  5. Model fitting + volumetric export
  6. Optional pattern-recognition ML stage

The script reuses the existing stage scripts in this repository. Existing
model-stage keys from 3_run_model.sh are still required. The following optional
config fields enable a full run:

  group_mask_source: "/abs/path/to/group_mask.nii.gz"

  registration: {
    "enabled": true,
    "input_dir": "/abs/path/to/qsirecon/derivatives",
    "qsiprep_dir": "/abs/path/to/qsiprep",
    "output_dir": "optional/output/tree",
    "modelarray_dir": ".",
    "mask_dir": "masks",
    "interpolation": "Linear",
    "resolution": "02",
    "jobs": 8,
    "force": false
  }

  cohort: {
    "enabled": true,
    "longitudinal": true,
    "participants_file": "/abs/path/to/participants.tsv",
    "scalar_dir": "optional/scalar/subdir",
    "mask_dir": "masks",
    "output_dir": ".",
    "subgroup": "column:value",
    "regenerate": false
  }

  convoxel: {
    "regenerate": false
  }

Options:
  --dry-run   Print the commands that would run without executing them.
  --nohup     Launch the run in background via nohup and return immediately.
EOF
  exit 1
}

ts() {
  echo "[$(date +%H:%M:%S)] $*"
}

quote_cmd() {
  printf '%q ' "$@"
}

run_step() {
  ts "$(quote_cmd "$@")"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  "$@"
}

resolve_config_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$CONFIG_DIR/$path"
  fi
}

resolve_data_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$DATA_DIR/$path"
  fi
}

json_string() {
  jq -r "$1 // empty" "$CONFIG_PATH"
}

json_bool() {
  jq -r "if ($1 // false) then \"true\" else \"false\" end" "$CONFIG_PATH"
}

DRY_RUN=false
NOHUP_MODE=false
CONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --nohup)
      NOHUP_MODE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      CONFIG_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$CONFIG_PATH" ]]; then
  usage
fi

CONFIG_PATH="$(realpath "$CONFIG_PATH")"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$CONFIG_PATH" ]] || { echo "ERROR: Config not found: $CONFIG_PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

if [[ "$NOHUP_MODE" == "true" ]]; then
  ts_stamp="$(date +%Y%m%d_%H%M%S)"
  cfg_base="$(basename "$CONFIG_PATH" .json)"
  log_file="/tmp/modelarray_full_${cfg_base}_${ts_stamp}.log"

  cmd=(bash "$SCRIPT_DIR/_run_scalar_pipeline.sh")
  if [[ "$DRY_RUN" == "true" ]]; then
    cmd+=(--dry-run)
  fi
  cmd+=("$CONFIG_PATH")

  ts "Launching detached run with nohup"
  ts "Log file: $log_file"
  nohup "${cmd[@]}" >"$log_file" 2>&1 &
  pid=$!
  ts "Started PID: $pid"
  exit 0
fi

# Delegate modality-level configs to the batch runner.
if jq -e 'has("dataset") and has("modality") and has("statistics")' "$CONFIG_PATH" >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == "true" ]]; then
    exec bash "$SCRIPT_DIR/_run_modality_batch.sh" --dry-run "$CONFIG_PATH"
  fi
  exec bash "$SCRIPT_DIR/_run_modality_batch.sh" "$CONFIG_PATH"
fi

RAW_DATA_DIR="$(json_string '.data_dir')"
CSV_FILE="$(json_string '.csv_file')"
H5_FILE="$(json_string '.h5_file')"
GROUP_MASK_FILE="$(json_string '.group_mask_file')"
SCALAR_TYPE="$(json_string '.scaler_type')"

[[ -n "$RAW_DATA_DIR" ]] || { echo "ERROR: data_dir is required in config." >&2; exit 1; }
[[ -n "$CSV_FILE" ]] || { echo "ERROR: csv_file is required in config." >&2; exit 1; }
[[ -n "$H5_FILE" ]] || { echo "ERROR: h5_file is required in config." >&2; exit 1; }
[[ -n "$GROUP_MASK_FILE" ]] || { echo "ERROR: group_mask_file is required in config." >&2; exit 1; }
[[ -n "$SCALAR_TYPE" ]] || { echo "ERROR: scaler_type is required in config." >&2; exit 1; }

if [[ "$RAW_DATA_DIR" = /* ]]; then
  DATA_DIR="$RAW_DATA_DIR"
else
  DATA_DIR="$CONFIG_DIR/$RAW_DATA_DIR"
fi

CSV_PATH="$(resolve_data_path "$CSV_FILE")"
H5_PATH="$(resolve_data_path "$H5_FILE")"
GROUP_MASK_PATH="$(resolve_data_path "$GROUP_MASK_FILE")"

GROUP_MASK_SOURCE="$(json_string '.group_mask_source')"

REG_ENABLED="$(json_bool '.registration.enabled')"
REG_INPUT_DIR="$(json_string '.registration.input_dir')"
REG_LINK_SOURCE_DIR="$(json_string '.registration.link_source_dir')"
REG_OUTPUT_DIR="$(json_string '.registration.output_dir')"
REG_MODELARRAY_DIR="$(json_string '.registration.modelarray_dir')"
REG_MASK_DIR="$(json_string '.registration.mask_dir')"
REG_QSIPREP_DIR="$(json_string '.registration.qsiprep_dir')"
REG_INTERP="$(json_string '.registration.interpolation')"
REG_RESOLUTION="$(json_string '.registration.resolution')"
REG_JOBS="$(json_string '.registration.jobs')"
REG_FORCE="$(json_bool '.registration.force')"

COHORT_ENABLED="$(json_bool '.cohort.enabled | if . == null then true else . end')"
COHORT_LONGITUDINAL="$(json_bool '.cohort.longitudinal | if . == null then true else . end')"
COHORT_PARTICIPANTS="$(json_string '.cohort.participants_file')"
COHORT_SCALAR_DIR="$(json_string '.cohort.scalar_dir')"
COHORT_MASK_DIR="$(json_string '.cohort.mask_dir')"
COHORT_OUTPUT_DIR="$(json_string '.cohort.output_dir')"
COHORT_SUBGROUP="$(json_string '.cohort.subgroup')"
COHORT_REGENERATE="$(json_bool '.cohort.regenerate')"

CONVOXEL_REGENERATE="$(json_bool '.convoxel.regenerate')"
ML_ENABLED="$(json_bool '.ml.enabled')"

mkdir -p "$DATA_DIR"

if [[ -z "$COHORT_SCALAR_DIR" ]]; then
  COHORT_SCALAR_DIR="$SCALAR_TYPE"
fi
if [[ -z "$COHORT_MASK_DIR" ]]; then
  COHORT_MASK_DIR="$(dirname "$GROUP_MASK_FILE")"
fi
if [[ -z "$COHORT_OUTPUT_DIR" ]]; then
  COHORT_OUTPUT_DIR="."
fi
if [[ -z "$REG_MODELARRAY_DIR" ]]; then
  REG_MODELARRAY_DIR="."
fi
if [[ -z "$REG_MASK_DIR" ]]; then
  REG_MASK_DIR="$COHORT_MASK_DIR"
fi

SCALAR_DIR_PATH="$(resolve_data_path "$COHORT_SCALAR_DIR")"
COHORT_MASK_DIR_PATH="$(resolve_data_path "$COHORT_MASK_DIR")"
COHORT_OUTPUT_DIR_PATH="$(resolve_data_path "$COHORT_OUTPUT_DIR")"
REG_MODELARRAY_DIR_PATH="$(resolve_data_path "$REG_MODELARRAY_DIR")"

SUFFIX=""
if [[ -n "$COHORT_SUBGROUP" ]]; then
  SUFFIX="_${COHORT_SUBGROUP%%:*}-${COHORT_SUBGROUP##*:}"
fi
EXPECTED_CSV_PATH="$(realpath -m "$COHORT_OUTPUT_DIR_PATH/cohort_$(basename "$SCALAR_DIR_PATH")${SUFFIX}.csv")"
CONFIGURED_CSV_PATH="$(realpath -m "$CSV_PATH")"
EXPECTED_H5_PATH="$(realpath -m "${EXPECTED_CSV_PATH%.csv}.h5")"
CONFIGURED_H5_PATH="$(realpath -m "$H5_PATH")"

if [[ "$EXPECTED_CSV_PATH" != "$CONFIGURED_CSV_PATH" ]]; then
  echo "ERROR: csv_file does not match the cohort generator output." >&2
  echo "       Expected: $EXPECTED_CSV_PATH" >&2
  echo "       Configured: $CONFIGURED_CSV_PATH" >&2
  exit 1
fi

if [[ "$EXPECTED_H5_PATH" != "$CONFIGURED_H5_PATH" ]]; then
  echo "ERROR: h5_file does not match the convoxel output path derived from csv_file." >&2
  echo "       Expected: $EXPECTED_H5_PATH" >&2
  echo "       Configured: $CONFIGURED_H5_PATH" >&2
  exit 1
fi

ts "Config: $CONFIG_PATH"
ts "Data dir: $DATA_DIR"
ts "Scalar: $SCALAR_TYPE"

if [[ "$REG_ENABLED" == "true" ]]; then
  ts "Step A: registration/linking"
  if [[ -z "$REG_INPUT_DIR" && -z "$REG_LINK_SOURCE_DIR" ]]; then
    echo "ERROR: registration.enabled is true, but neither registration.input_dir nor registration.link_source_dir is set." >&2
    exit 1
  fi

  reg_cmd=(bash "$SCRIPT_DIR/0_register_acpc_to_mni.sh")
  if [[ -n "$REG_LINK_SOURCE_DIR" ]]; then
    reg_cmd+=(-L "$(resolve_config_path "$REG_LINK_SOURCE_DIR")")
  else
    reg_cmd+=(-i "$(resolve_config_path "$REG_INPUT_DIR")")
  fi
  reg_cmd+=(-m "$REG_MODELARRAY_DIR_PATH")

  if [[ -n "$REG_OUTPUT_DIR" ]]; then
    reg_cmd+=(-o "$(resolve_data_path "$REG_OUTPUT_DIR")")
  fi
  if [[ -n "$REG_MASK_DIR" ]]; then
    reg_cmd+=(-b "$(resolve_data_path "$REG_MASK_DIR")")
  fi
  if [[ -n "$REG_QSIPREP_DIR" ]]; then
    reg_cmd+=(-q "$(resolve_config_path "$REG_QSIPREP_DIR")")
  fi
  if [[ -n "$REG_INTERP" ]]; then
    reg_cmd+=(-n "$REG_INTERP")
  fi
  if [[ -n "$REG_RESOLUTION" ]]; then
    reg_cmd+=(-s "$REG_RESOLUTION")
  fi
  if [[ -n "$REG_JOBS" ]]; then
    reg_cmd+=(-j "$REG_JOBS")
  fi
  if [[ "$REG_FORCE" == "true" ]]; then
    reg_cmd+=(-f)
  fi

  run_step "${reg_cmd[@]}"
fi

ts "Step B: preparing group mask"
if [[ ! -f "$GROUP_MASK_PATH" ]]; then
  if [[ -z "$GROUP_MASK_SOURCE" ]]; then
    echo "ERROR: group mask missing at $GROUP_MASK_PATH and no group_mask_source is configured." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$GROUP_MASK_PATH")"
  run_step cp "$(resolve_config_path "$GROUP_MASK_SOURCE")" "$GROUP_MASK_PATH"
fi

mkdir -p "$COHORT_MASK_DIR_PATH"
MASK_DIR_GROUP_MASK="$COHORT_MASK_DIR_PATH/$(basename "$GROUP_MASK_PATH")"
if [[ "$MASK_DIR_GROUP_MASK" != "$GROUP_MASK_PATH" && ! -f "$MASK_DIR_GROUP_MASK" ]]; then
  run_step cp "$GROUP_MASK_PATH" "$MASK_DIR_GROUP_MASK"
fi

if [[ ! -d "$SCALAR_DIR_PATH" ]]; then
  echo "ERROR: Scalar directory not found: $SCALAR_DIR_PATH" >&2
  exit 1
fi

ts "Step C: cohort generation"
if [[ ! -f "$CSV_PATH" || "$COHORT_REGENERATE" == "true" ]]; then
  if [[ "$COHORT_ENABLED" != "true" ]]; then
    echo "ERROR: cohort generation is disabled, but csv_file is missing: $CSV_PATH" >&2
    exit 1
  fi
  if [[ -z "$COHORT_PARTICIPANTS" ]]; then
    echo "ERROR: cohort.participants_file is required to generate the cohort CSV." >&2
    exit 1
  fi

  mkdir -p "$COHORT_OUTPUT_DIR_PATH"
  if [[ "$COHORT_LONGITUDINAL" == "true" ]]; then
    cohort_script="$SCRIPT_DIR/1_generate_cohort_longitudinal.sh"
  else
    cohort_script="$SCRIPT_DIR/1_generate_cohort.sh"
  fi

  cohort_cmd=(
    bash "$cohort_script"
    -p "$(resolve_config_path "$COHORT_PARTICIPANTS")"
    -d "$SCALAR_DIR_PATH"
    -m "$COHORT_MASK_DIR_PATH"
    -o "$COHORT_OUTPUT_DIR_PATH"
  )
  if [[ -n "$COHORT_SUBGROUP" ]]; then
    cohort_cmd+=(-s "$COHORT_SUBGROUP")
  fi

  run_step "${cohort_cmd[@]}"
else
  ts "  skipping: cohort CSV already exists at $CSV_PATH"
fi

ts "Step D: convoxel HDF5"
if [[ ! -f "$H5_PATH" || "$CONVOXEL_REGENERATE" == "true" ]]; then
  run_step bash "$SCRIPT_DIR/2_run_convoxel.sh" -c "$CSV_PATH" -g "$GROUP_MASK_PATH"
else
  ts "  skipping: HDF5 already exists at $H5_PATH"
fi

ts "Step E: model fitting"
run_step bash "$SCRIPT_DIR/3_run_model.sh" "$CONFIG_PATH"

if [[ "$ML_ENABLED" == "true" ]]; then
  ts "Step F: pattern-recognition ML"
  run_step python3 "$SCRIPT_DIR/4_run_ml.py" "$CONFIG_PATH"
fi

ts "All requested steps completed."
