#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run_family_from_json.sh [--dry-run] /path/to/config.json

Runs a modality-level ModelArray workflow from a higher-level JSON config.
The config describes the dataset, qsirecon source, output folder, modality,
and shared statistics template once; the script derives per-scalar configs and
then runs the existing scalar-level pipeline for each selected scalar.
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

fmt_duration() {
  local total="$1"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

find_group_mask_reference() {
  local mask_dir="$1"
  local scalar_root="$2"
  local reference=""

  if [[ -d "$mask_dir" ]]; then
    reference=$(find "$mask_dir" -maxdepth 1 \( -type f -o -type l \) -name 'sub-*.nii.gz' ! -name 'group_mask.nii.gz' | sort | head -n 1)
  fi

  if [[ -z "$reference" && -d "$scalar_root" ]]; then
    reference=$(find "$scalar_root" -mindepth 2 -maxdepth 2 \( -type f -o -type l \) -name '*.nii.gz' | sort | head -n 1)
  fi

  printf '%s\n' "$reference"
}

ensure_group_mask_grid() {
  local group_mask="$1"
  local reference="$2"
  local group_dim=""
  local reference_dim=""
  local tmp_mask=""

  [[ "$DRY_RUN" == "true" ]] && return 0
  [[ -f "$group_mask" && -n "$reference" && -f "$reference" ]] || return 0

  group_dim=$(mrinfo "$group_mask" -quiet -size | tr -d '\n')
  reference_dim=$(mrinfo "$reference" -quiet -size | tr -d '\n')
  [[ "$group_dim" != "$reference_dim" ]] || return 0

  command -v mrtransform >/dev/null 2>&1 || { echo "ERROR: mrtransform is required to resample the group mask." >&2; exit 1; }

  ts "  resampling group mask to match $(basename "$reference") (${group_dim} -> ${reference_dim})"
  tmp_mask="$(mktemp -u "$(dirname "$group_mask")/.group_mask_resampled_XXXXXX.nii.gz")"
  mrtransform "$group_mask" -template "$reference" -interp nearest "$tmp_mask"
  mv -f "$tmp_mask" "$group_mask"
}

json_string() {
  jq -r "$1 // empty" "$CONFIG_PATH"
}

json_bool() {
  jq -r "if ($1 // false) then \"true\" else \"false\" end" "$CONFIG_PATH"
}

render_template() {
  local template="$1"
  local scalar="$2"
  local rendered="$template"
  rendered="${rendered//\{scalar\}/$scalar}"
  rendered="${rendered//\{modality\}/$MODALITY_NAME}"
  rendered="${rendered//\{model_type\}/$MODEL_TYPE}"
  rendered="${rendered//\{resolution\}/$REG_RESOLUTION}"
  printf '%s\n' "$rendered"
}

render_ml_for_scalar() {
  local scalar="$1"
  local ml_json="$ML_JSON"

  if [[ "$ml_json" == "{}" ]]; then
    printf '{}\n'
    return
  fi

  local output_dir=""
  local metrics_file=""
  local predictions_file=""
  local summary_file=""
  local template=""

  template="$(jq -r '.output_dir_template // empty' <<<"$ml_json")"
  if [[ -n "$template" ]]; then
    output_dir="$(render_template "$template" "$scalar")"
  fi

  template="$(jq -r '.metrics_file_template // empty' <<<"$ml_json")"
  if [[ -n "$template" ]]; then
    metrics_file="$(render_template "$template" "$scalar")"
  fi

  template="$(jq -r '.predictions_file_template // empty' <<<"$ml_json")"
  if [[ -n "$template" ]]; then
    predictions_file="$(render_template "$template" "$scalar")"
  fi

  template="$(jq -r '.summary_file_template // empty' <<<"$ml_json")"
  if [[ -n "$template" ]]; then
    summary_file="$(render_template "$template" "$scalar")"
  fi

  jq -c \
    --arg output_dir "$output_dir" \
    --arg metrics_file "$metrics_file" \
    --arg predictions_file "$predictions_file" \
    --arg summary_file "$summary_file" \
    '
      del(.output_dir_template, .metrics_file_template, .predictions_file_template, .summary_file_template)
      | (if ($output_dir | length) > 0 then .output_dir = $output_dir else . end)
      | (if ($metrics_file | length) > 0 then .metrics_file = $metrics_file else . end)
      | (if ($predictions_file | length) > 0 then .predictions_file = $predictions_file else . end)
      | (if ($summary_file | length) > 0 then .summary_file = $summary_file else . end)
    ' <<<"$ml_json"
}

default_qsiprep_dir() {
  local from_config
  from_config="$(json_string '.dataset.qsiprep_dir')"
  if [[ -n "$from_config" ]]; then
    printf '%s\n' "$from_config"
    return
  fi

  local candidate
  candidate="$BIDS_DIR/derivatives/qsiprep"
  if [[ -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  printf '%s\n' ""
}

default_group_mask_source() {
  local configured
  configured="$(json_string '.registration.group_mask_source')"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return
  fi

  if [[ "$REG_RESOLUTION" =~ ^[0-9]{2}$ ]]; then
    printf '/data/local/templateflow/tpl-MNI152NLin2009cAsym/tpl-MNI152NLin2009cAsym_res-%s_desc-brain_mask.nii.gz\n' "$REG_RESOLUTION"
    return
  fi

  printf '%s\n' ""
}

default_participants_source() {
  local configured
  configured="$(json_string '.cohort.participants_file')"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return
  fi

  local candidates=(
    "$BIDS_DIR/participants.tsv"
    "$BIDS_DIR/derivatives/modelarray/participants.tsv"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  printf '%s\n' ""
}

DRY_RUN=false
CONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
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

[[ -n "$CONFIG_PATH" ]] || usage

CONFIG_PATH="$(realpath "$CONFIG_PATH")"
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$CONFIG_PATH" ]] || { echo "ERROR: Config not found: $CONFIG_PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

jq -e 'has("dataset") and has("modality") and has("statistics")' "$CONFIG_PATH" >/dev/null \
  || { echo "ERROR: This runner expects a high-level config with dataset, modality, and statistics sections." >&2; exit 1; }

BIDS_DIR="$(json_string '.dataset.bids_dir')"
QSIRECON_DIR="$(json_string '.dataset.qsirecon_dir')"
OUTPUT_DIR="$(json_string '.dataset.output_dir')"
CONTAINER="$(json_string '.container')"
MODALITY_NAME="$(json_string '.modality.name')"

[[ -n "$BIDS_DIR" ]] || { echo "ERROR: dataset.bids_dir is required." >&2; exit 1; }
[[ -n "$QSIRECON_DIR" ]] || { echo "ERROR: dataset.qsirecon_dir is required." >&2; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: dataset.output_dir is required." >&2; exit 1; }
[[ -n "$MODALITY_NAME" ]] || { echo "ERROR: modality.name is required." >&2; exit 1; }

[[ -d "$BIDS_DIR" ]] || { echo "ERROR: dataset.bids_dir not found: $BIDS_DIR" >&2; exit 1; }
[[ -d "$QSIRECON_DIR" ]] || { echo "ERROR: dataset.qsirecon_dir not found: $QSIRECON_DIR" >&2; exit 1; }

if [[ -z "$CONTAINER" ]]; then
  CONTAINER="/data/local/container/modelarray/modelarray_confixel_0.1.5.sif"
fi
[[ -f "$CONTAINER" ]] || { echo "ERROR: container not found: $CONTAINER" >&2; exit 1; }

MODEL_TYPE="$(json_string '.statistics.model_type')"
FORMULA_TEMPLATE="$(json_string '.statistics.formula_template')"
[[ -n "$MODEL_TYPE" ]] || { echo "ERROR: statistics.model_type is required." >&2; exit 1; }
[[ -n "$FORMULA_TEMPLATE" ]] || { echo "ERROR: statistics.formula_template is required." >&2; exit 1; }

REG_ENABLED="$(json_bool '.registration.enabled | if . == null then true else . end')"
REG_INTERP="$(json_string '.registration.interpolation')"
REG_RESOLUTION="$(json_string '.registration.resolution')"
REG_JOBS="$(json_string '.registration.jobs')"
REG_FORCE="$(json_bool '.registration.force')"
if [[ -z "$REG_INTERP" ]]; then REG_INTERP="Linear"; fi
if [[ -z "$REG_RESOLUTION" ]]; then REG_RESOLUTION="02"; fi
if [[ -z "$REG_JOBS" ]]; then REG_JOBS="4"; fi

QSIPREP_DIR="$(default_qsiprep_dir)"
GROUP_MASK_SOURCE="$(default_group_mask_source)"

PARTICIPANTS_SOURCE="$(default_participants_source)"
[[ -f "$PARTICIPANTS_SOURCE" ]] || { echo "ERROR: participants file not found: $PARTICIPANTS_SOURCE" >&2; exit 1; }

COHORT_LONGITUDINAL="$(json_bool '.cohort.longitudinal | if . == null then true else . end')"
COHORT_SUBGROUP="$(json_string '.cohort.subgroup')"
COHORT_REGENERATE="$(json_bool '.cohort.regenerate')"
PARTICIPANTS_REGENERATE="$(json_bool '.cohort.regenerate_participants_longitudinal')"
CONVOXEL_REGENERATE="$(json_bool '.convoxel.regenerate')"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/configs/generated"
mkdir -p "$OUTPUT_DIR/results"

PARTICIPANTS_FOR_COHORT="$PARTICIPANTS_SOURCE"
if [[ "$COHORT_LONGITUDINAL" == "true" ]]; then
  if head -n1 "$PARTICIPANTS_SOURCE" | grep -q $'\tparticipant\t' && head -n1 "$PARTICIPANTS_SOURCE" | grep -q $'\tsession\b'; then
    PARTICIPANTS_FOR_COHORT="$PARTICIPANTS_SOURCE"
  else
    PARTICIPANTS_FOR_COHORT="$OUTPUT_DIR/participants_longitudinal.tsv"
    if [[ ! -f "$PARTICIPANTS_FOR_COHORT" || "$PARTICIPANTS_REGENERATE" == "true" ]]; then
      run_step bash "$SCRIPT_DIR/prepare_longitudinal_participants.sh" \
        -p "$PARTICIPANTS_SOURCE" \
        -q "$QSIRECON_DIR" \
        -o "$PARTICIPANTS_FOR_COHORT"
    else
      ts "Skipping longitudinal participant derivation: $PARTICIPANTS_FOR_COHORT already exists"
    fi
  fi
fi

mapfile -t SCALARS < <(jq -r '.modality.scalars[]? // empty' "$CONFIG_PATH")
if [[ ${#SCALARS[@]} -eq 0 ]]; then
  case "$MODALITY_NAME" in
    noddi)
      SCALARS=(icvf_dwimap od_dwimap isovf_dwimap)
      ;;
    *)
      echo "ERROR: No default scalar list for modality '$MODALITY_NAME'. Set modality.scalars explicitly." >&2
      exit 1
      ;;
  esac
fi

ANALYSIS_NAME_TEMPLATE="$(json_string '.statistics.analysis_name_template')"
CSV_SUMMARY_TEMPLATE="$(json_string '.statistics.csv_summary_template')"
RESULT_DIR_TEMPLATE="$(json_string '.statistics.result_dir_template')"
if [[ -z "$ANALYSIS_NAME_TEMPLATE" ]]; then
  ANALYSIS_NAME_TEMPLATE="{scalar}_{model_type}_{resolution}"
fi
if [[ -z "$CSV_SUMMARY_TEMPLATE" ]]; then
  CSV_SUMMARY_TEMPLATE="results/{scalar}_{model_type}_{resolution}/summary_{scalar}_{model_type}_{resolution}.csv"
fi
if [[ -z "$RESULT_DIR_TEMPLATE" ]]; then
  RESULT_DIR_TEMPLATE="results/{scalar}_{model_type}_{resolution}"
fi

N_CORES="$(json_string '.statistics.n_cores')"
NUM_ABS="$(json_string '.statistics.num_subj_lthr_abs')"
NUM_REL="$(json_string '.statistics.num_subj_lthr_rel')"
FULL_OUTPUTS="$(json_bool '.statistics.full_outputs | if . == null then true else . end')"
OUTPUT_EXT="$(json_string '.statistics.output_ext')"
if [[ -z "$N_CORES" ]]; then N_CORES="4"; fi
if [[ -z "$NUM_ABS" ]]; then NUM_ABS="10"; fi
if [[ -z "$NUM_REL" ]]; then NUM_REL="0.1"; fi
if [[ -z "$OUTPUT_EXT" ]]; then OUTPUT_EXT=".nii.gz"; fi

CATEGORICAL_VARIABLES_JSON="$(jq -c '.statistics.categorical_variables // []' "$CONFIG_PATH")"
CONTINUOUS_COVARIATES_JSON="$(jq -c '.statistics.continuous_covariates // []' "$CONFIG_PATH")"
ELEMENT_SUBSET_JSON="$(jq -c '.statistics.element_subset // null' "$CONFIG_PATH")"
ELEMENT_RANGE_JSON="$(jq -c '.statistics.element_range // null' "$CONFIG_PATH")"
MODEL_OPTIONS_JSON="$(jq -c '.statistics.model_options // {}' "$CONFIG_PATH")"
ML_JSON="$(jq -c '.statistics.ml // {}' "$CONFIG_PATH")"

if [[ "$REG_ENABLED" == "true" ]]; then
  [[ -n "$QSIPREP_DIR" ]] || { echo "ERROR: Could not infer qsiprep directory. Set dataset.qsiprep_dir explicitly." >&2; exit 1; }
  [[ -d "$QSIPREP_DIR" ]] || { echo "ERROR: qsiprep directory not found: $QSIPREP_DIR" >&2; exit 1; }

  reg_cmd=(
    bash "$SCRIPT_DIR/0_register_acpc_to_mni.sh"
    -i "$QSIRECON_DIR"
    -m "$OUTPUT_DIR"
    -b "$OUTPUT_DIR/masks"
    -q "$QSIPREP_DIR"
    -n "$REG_INTERP"
    -s "$REG_RESOLUTION"
    -j "$REG_JOBS"
  )
  if [[ "$REG_FORCE" == "true" ]]; then
    reg_cmd+=(-f)
  fi
  run_step "${reg_cmd[@]}"
fi

GROUP_MASK_PATH="$OUTPUT_DIR/group_mask.nii.gz"
if [[ ! -f "$GROUP_MASK_PATH" ]]; then
  [[ -n "$GROUP_MASK_SOURCE" ]] || { echo "ERROR: No group mask at $GROUP_MASK_PATH and no registration.group_mask_source could be resolved." >&2; exit 1; }
  mkdir -p "$OUTPUT_DIR/masks"
  run_step cp "$GROUP_MASK_SOURCE" "$GROUP_MASK_PATH"
fi
GROUP_MASK_REFERENCE="$(find_group_mask_reference "$OUTPUT_DIR/masks" "$OUTPUT_DIR")"
ensure_group_mask_grid "$GROUP_MASK_PATH" "$GROUP_MASK_REFERENCE"
mkdir -p "$OUTPUT_DIR/masks"
run_step cp -f "$GROUP_MASK_PATH" "$OUTPUT_DIR/masks/group_mask.nii.gz"

ts "Using scalars: ${SCALARS[*]}"
ts "Output root: $OUTPUT_DIR"
ts "Participants for cohort: $PARTICIPANTS_FOR_COHORT"

SCALAR_TOTAL=${#SCALARS[@]}
SCALAR_INDEX=0
FAMILY_START_EPOCH=$(date +%s)

for scalar in "${SCALARS[@]}"; do
  SCALAR_INDEX=$((SCALAR_INDEX + 1))
  SCALAR_START_EPOCH=$(date +%s)
  ts "Scalar ${SCALAR_INDEX}/${SCALAR_TOTAL}: $scalar"

  formula="$(render_template "$FORMULA_TEMPLATE" "$scalar")"
  analysis_name="$(render_template "$ANALYSIS_NAME_TEMPLATE" "$scalar")"
  csv_summary_path="$(render_template "$CSV_SUMMARY_TEMPLATE" "$scalar")"
  result_dir="$(render_template "$RESULT_DIR_TEMPLATE" "$scalar")"
  ml_scalar_json="$(render_ml_for_scalar "$scalar")"
  derived_config="$OUTPUT_DIR/configs/generated/${scalar}.json"

  jq -n \
    --arg analysis_name "$analysis_name" \
    --arg container "$CONTAINER" \
    --arg data_dir "$OUTPUT_DIR" \
    --arg csv_file "cohort_${scalar}.csv" \
    --arg csv_summary_path "$csv_summary_path" \
    --arg formula "$formula" \
    --arg group_mask_file "group_mask.nii.gz" \
    --arg h5_file "cohort_${scalar}.h5" \
    --arg model_type "$MODEL_TYPE" \
    --arg output_dir "$result_dir" \
    --arg output_ext "$OUTPUT_EXT" \
    --arg participants_file "$PARTICIPANTS_FOR_COHORT" \
    --arg scaler_type "$scalar" \
    --arg subgroup "$COHORT_SUBGROUP" \
    --argjson categorical_variables "$CATEGORICAL_VARIABLES_JSON" \
    --argjson continuous_covariates "$CONTINUOUS_COVARIATES_JSON" \
    --argjson element_range "$ELEMENT_RANGE_JSON" \
    --argjson element_subset "$ELEMENT_SUBSET_JSON" \
    --argjson full_outputs "$FULL_OUTPUTS" \
    --argjson model_options "$MODEL_OPTIONS_JSON" \
    --argjson ml "$ml_scalar_json" \
    --argjson n_cores "$N_CORES" \
    --argjson num_subj_lthr_abs "$NUM_ABS" \
    --argjson num_subj_lthr_rel "$NUM_REL" \
    --argjson cohort_longitudinal "$COHORT_LONGITUDINAL" \
    --argjson cohort_regenerate "$COHORT_REGENERATE" \
    --argjson convoxel_regenerate "$CONVOXEL_REGENERATE" \
    '
      {
        analysis_name: $analysis_name,
        categorical_variables: $categorical_variables,
        cohort: {
          enabled: true,
          longitudinal: $cohort_longitudinal,
          mask_dir: "masks",
          output_dir: ".",
          participants_file: $participants_file,
          regenerate: $cohort_regenerate
        },
        container: $container,
        continuous_covariates: $continuous_covariates,
        csv_file: $csv_file,
        csv_summary_path: $csv_summary_path,
        data_dir: $data_dir,
        formula: $formula,
        full_outputs: $full_outputs,
        group_mask_file: $group_mask_file,
        h5_file: $h5_file,
        model_type: $model_type,
        n_cores: $n_cores,
        num_subj_lthr_abs: $num_subj_lthr_abs,
        num_subj_lthr_rel: $num_subj_lthr_rel,
        output_dir: $output_dir,
        output_ext: $output_ext,
        convoxel: {
          regenerate: $convoxel_regenerate
        },
        registration: {
          enabled: false
        },
        scaler_type: $scaler_type
      }
      + (if ($subgroup | length) > 0 then {cohort: (.cohort + {subgroup: $subgroup})} else {} end)
      + (if $element_subset != null then {element_subset: $element_subset} else {} end)
      + (if $element_range != null then {element_range: $element_range} else {} end)
      + (if $model_options != {} then {model_options: $model_options} else {} end)
      + (if $ml != {} then {ml: $ml} else {} end)
    ' > "$derived_config"

  ts "Generated config: $derived_config"
  if [[ "$DRY_RUN" == "true" ]]; then
    run_step bash "$SCRIPT_DIR/run_full_from_json.sh" --dry-run "$derived_config"
  else
    run_step bash "$SCRIPT_DIR/run_full_from_json.sh" "$derived_config"
  fi

  SCALAR_ELAPSED=$(( $(date +%s) - SCALAR_START_EPOCH ))
  FAMILY_ELAPSED=$(( $(date +%s) - FAMILY_START_EPOCH ))
  FAMILY_PCT=$((SCALAR_INDEX * 100 / SCALAR_TOTAL))
  ts "Scalar ${SCALAR_INDEX}/${SCALAR_TOTAL} complete: $scalar in $(fmt_duration "$SCALAR_ELAPSED") | overall ${FAMILY_PCT}% in $(fmt_duration "$FAMILY_ELAPSED")"
done

ts "All scalar pipelines completed."