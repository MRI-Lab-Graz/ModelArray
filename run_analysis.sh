#!/usr/bin/env bash
#
# run_analysis.sh — Unified ModelArray analysis entry point
#
# Runs voxelwise statistical analysis + optional ML from a JSON config.
# Automatically detects whether the config describes:
#   - A MODALITY (multiple scalars, e.g., NODDI, MAPMRI) → batch mode
#   - A single SCALAR (e.g., icvf_dwimap) → single pipeline mode
#
# Usage:
#   run_analysis.sh [OPTIONS] /path/to/config.json
#
# Options:
#   --dry-run       Print commands without executing
#   --nohup         Run detached in background (logs to /tmp/)
#   --scalar NAME   Run only this scalar (modality configs only)
#   --skip-reg      Skip registration step
#   --skip-ml       Skip machine learning step
#   --force         Regenerate all intermediate files
#   -h, --help      Show this help message
#
# Config types:
#   Modality config (batch):
#     - Contains: dataset, modality, statistics sections
#     - Processes all scalars in modality.scalars[]
#     - Example: pipeline_noddi_gam_2mm.json
#
#   Scalar config (single):
#     - Contains: data_dir, csv_file, h5_file, formula, etc.
#     - Processes one scalar end-to-end
#     - Example: config_noddi_icvf_gam.json
#
# Pipeline steps (per scalar):
#   A. Registration/linking to MNI space
#   B. Group mask preparation
#   C. Cohort CSV generation
#   D. ConVoxel HDF5 creation
#   E. Statistical model fitting (GAM/LM)
#   F. Pattern-recognition ML (optional)
#
# Examples:
#   # Run full MAPMRI analysis (6 scalars)
#   ./run_analysis.sh configs/pipeline_mapmri_wholebrain_2group_gam_2mm.json
#
#   # Dry-run to see what would happen
#   ./run_analysis.sh --dry-run configs/pipeline_noddi_gam_2mm.json
#
#   # Run in background with nohup
#   ./run_analysis.sh --nohup configs/pipeline_noddi_gam_2mm.json
#
#   # Run only one scalar from a modality config
#   ./run_analysis.sh --scalar icvf_dwimap configs/pipeline_noddi_gam_2mm.json
#
#   # Skip ML step
#   ./run_analysis.sh --skip-ml configs/pipeline_noddi_gam_2mm.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors for terminal output ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Helper functions ─────────────────────────────────────────────────────────
ts() {
  echo -e "[$(date +%H:%M:%S)] $*"
}

error() {
  echo -e "${RED}ERROR:${NC} $*" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}WARNING:${NC} $*" >&2
}

info() {
  echo -e "${BLUE}INFO:${NC} $*"
}

usage() {
  head -n 55 "$0" | grep -E '^#' | sed 's/^# \?//'
  exit 0
}

# ─── Parse arguments ──────────────────────────────────────────────────────────
DRY_RUN=false
NOHUP_MODE=false
SINGLE_SCALAR=""
SKIP_REG=false
SKIP_ML=false
FORCE_REGEN=false
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
    --scalar)
      SINGLE_SCALAR="$2"
      shift 2
      ;;
    --skip-reg)
      SKIP_REG=true
      shift
      ;;
    --skip-ml)
      SKIP_ML=true
      shift
      ;;
    --force)
      FORCE_REGEN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      error "Unknown option: $1"
      ;;
    *)
      if [[ -n "$CONFIG_PATH" ]]; then
        error "Multiple config files specified. Only one allowed."
      fi
      CONFIG_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$CONFIG_PATH" ]] || { echo "Usage: run_analysis.sh [OPTIONS] /path/to/config.json"; exit 1; }
[[ -f "$CONFIG_PATH" ]] || error "Config file not found: $CONFIG_PATH"
command -v jq >/dev/null 2>&1 || error "jq is required but not installed"

CONFIG_PATH="$(realpath "$CONFIG_PATH")"
CONFIG_NAME="$(basename "$CONFIG_PATH" .json)"

# ─── Detect config type ───────────────────────────────────────────────────────
is_modality_config() {
  jq -e 'has("dataset") and has("modality") and has("statistics")' "$CONFIG_PATH" >/dev/null 2>&1
}

is_scalar_config() {
  jq -e 'has("data_dir") and has("csv_file") and has("h5_file")' "$CONFIG_PATH" >/dev/null 2>&1
}

if is_modality_config; then
  CONFIG_TYPE="modality"
  MODALITY_NAME="$(jq -r '.modality.name // "unknown"' "$CONFIG_PATH")"
  SCALAR_COUNT="$(jq -r '.modality.scalars | length' "$CONFIG_PATH")"
  info "Detected ${GREEN}modality-level${NC} config: ${MODALITY_NAME} (${SCALAR_COUNT} scalars)"
elif is_scalar_config; then
  CONFIG_TYPE="scalar"
  SCALAR_NAME="$(jq -r '.scaler_type // "unknown"' "$CONFIG_PATH")"
  info "Detected ${GREEN}scalar-level${NC} config: ${SCALAR_NAME}"
else
  error "Unrecognized config format. Expected modality or scalar config structure."
fi

# ─── Apply runtime overrides to config ────────────────────────────────────────
TEMP_CONFIG=""

apply_overrides() {
  local src="$1"
  local dst
  dst="$(mktemp --suffix=.json)"
  
  local jq_filter="."
  
  if [[ "$SKIP_REG" == "true" ]]; then
    jq_filter="$jq_filter | .registration.enabled = false"
  fi
  
  if [[ "$SKIP_ML" == "true" ]]; then
    if [[ "$CONFIG_TYPE" == "modality" ]]; then
      jq_filter="$jq_filter | .statistics.ml.enabled = false"
    else
      jq_filter="$jq_filter | .ml.enabled = false"
    fi
  fi
  
  if [[ "$FORCE_REGEN" == "true" ]]; then
    jq_filter="$jq_filter | .cohort.regenerate = true | .convoxel.regenerate = true"
    if [[ "$CONFIG_TYPE" == "modality" ]]; then
      jq_filter="$jq_filter | .registration.force = true"
    fi
  fi
  
  if [[ -n "$SINGLE_SCALAR" && "$CONFIG_TYPE" == "modality" ]]; then
    jq_filter="$jq_filter | .modality.scalars = [\"$SINGLE_SCALAR\"]"
  fi
  
  jq "$jq_filter" "$src" > "$dst"
  echo "$dst"
}

if [[ "$SKIP_REG" == "true" || "$SKIP_ML" == "true" || "$FORCE_REGEN" == "true" || -n "$SINGLE_SCALAR" ]]; then
  TEMP_CONFIG="$(apply_overrides "$CONFIG_PATH")"
  CONFIG_PATH="$TEMP_CONFIG"
  info "Applied runtime overrides to config"
fi

cleanup() {
  [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]] && rm -f "$TEMP_CONFIG"
}
trap cleanup EXIT

# ─── Nohup mode ───────────────────────────────────────────────────────────────
if [[ "$NOHUP_MODE" == "true" ]]; then
  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  LOG_DIR="/tmp"
  
  # For modality configs, also check output_dir for log placement
  if [[ "$CONFIG_TYPE" == "modality" ]]; then
    OUTPUT_DIR="$(jq -r '.dataset.output_dir // empty' "$CONFIG_PATH")"
    if [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
      LOG_DIR="$OUTPUT_DIR"
    fi
  fi
  
  LOG_FILE="${LOG_DIR}/nohup_${CONFIG_TYPE}_${TIMESTAMP}.log"
  
  # Build command with original args (excluding --nohup)
  CMD=(bash "$0")
  [[ "$DRY_RUN" == "true" ]] && CMD+=(--dry-run)
  [[ "$SKIP_REG" == "true" ]] && CMD+=(--skip-reg)
  [[ "$SKIP_ML" == "true" ]] && CMD+=(--skip-ml)
  [[ "$FORCE_REGEN" == "true" ]] && CMD+=(--force)
  [[ -n "$SINGLE_SCALAR" ]] && CMD+=(--scalar "$SINGLE_SCALAR")
  CMD+=("$(realpath "$CONFIG_PATH")")
  
  ts "Launching detached run with nohup"
  ts "Log file: ${GREEN}$LOG_FILE${NC}"
  ts "Monitor with: ${BLUE}tail -f $LOG_FILE${NC}"
  
  nohup "${CMD[@]}" > "$LOG_FILE" 2>&1 &
  PID=$!
  ts "Started PID: ${GREEN}$PID${NC}"
  exit 0
fi

# ─── Dispatch to appropriate runner ───────────────────────────────────────────
ts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ts "ModelArray Analysis Pipeline"
ts "Config: ${GREEN}$CONFIG_NAME${NC}"
ts "Type: ${BLUE}$CONFIG_TYPE${NC}"
ts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RUNNER_ARGS=()
[[ "$DRY_RUN" == "true" ]] && RUNNER_ARGS+=(--dry-run)

if [[ "$CONFIG_TYPE" == "modality" ]]; then
  # Modality config → run batch across all scalars
  exec bash "$SCRIPT_DIR/_run_modality_batch.sh" "${RUNNER_ARGS[@]}" "$CONFIG_PATH"
else
  # Scalar config → run single pipeline
  exec bash "$SCRIPT_DIR/_run_scalar_pipeline.sh" "${RUNNER_ARGS[@]}" "$CONFIG_PATH"
fi
