#!/bin/bash
# Register ACPC-space scalar maps to MNI152NLin2009cAsym space
# using subject-level transforms from QSIPrep and a local TemplateFlow reference.
#
# Usage:
#   ./0_register_acpc_to_mni.sh -i INPUT_DIR [options]
#
# Input directory must be organized as:
#   INPUT_DIR/sub-<id>/ses-<id>/{dwi/}<scalar>_ACPC.nii.gz
#   or any *.nii.gz containing "ACPC" or "space-ACPC" in the filename.
# By default, MNI outputs are written alongside the ACPC inputs in the same folder.

set -e
set -o pipefail

# ── Fixed paths ────────────────────────────────────────────────────────────────
QSIPREP_DIR="/data/local/134_AF19/derivatives/qsiprep"
TEMPLATE_DIR="/data/local/templateflow/tpl-MNI152NLin2009cAsym"
TEMPLATE_PREFIX="tpl-MNI152NLin2009cAsym"
TEMPLATE=""  # resolved after arg parsing

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 -i INPUT_DIR [options]

Required:
  -i  Input directory with ACPC-space scalar maps
        Expected layout: INPUT_DIR/sub-<id>/ses-<id>/[dwi/]*.nii.gz

Optional:
  -o  Output directory for MNI-space scalar maps (same layout)
        [default: write MNI files alongside ACPC files in INPUT_DIR]
  -m  ModelArray directory: creates a flat tree of symlinks organised by
        scalar/parameter name, ready for 1_generate_cohort.sh:
        MODELARRAY_DIR/{param}/sub-xxx_ses-x_..._MNI_...nii.gz
        [default: not created]
  -q  QSIPrep derivatives directory  [default: ${QSIPREP_DIR}]
  -n  ANTs interpolation method      [default: Linear]
        (Linear | NearestNeighbor | BSpline | LanczosWindowedSinc | ...)
  -s  Output resolution                [default: 01]
        TemplateFlow res tag number only, e.g. -s 02  (not -s res-02).
        Must match a file: tpl-MNI152NLin2009cAsym_res-XX_T1w.nii.gz.
        Check zooms in template_description.json for actual voxel sizes.
        Or a float mm value (e.g. -s 2.3) — the MNI res-01 template will be
        resampled isotropically to that spacing with ResampleImageBySpacing.
        Controls the voxel grid that antsApplyTransforms resamples to.
  -j  Parallel jobs via GNU parallel [default: 1, sequential]
  -f  Force overwrite existing files [default: skip existing]
  -h  Show this help

Examples:
  # Write MNI maps next to the ACPC maps (in-place):
  $0 -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI

  # Write to a separate output tree:
  $0 -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI \\
     -o /data/local/134_AF19/derivatives/qsirecon-NODDI_MNI \\
     -n Linear -j 4

  # Register to res-02 MNI space (2mm isotropic for MNI152NLin2009cAsym):
  $0 -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI \\
     -o /data/local/134_AF19/derivatives/qsirecon-NODDI_MNI_res-02 \\
     -s 02 -n Linear -j 4

  # Register to a custom isotropic spacing (resamples res-01 template on the fly):
  $0 -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI \\
     -o /data/local/134_AF19/derivatives/qsirecon-NODDI_MNI_2.3mm \\
     -s 2.3 -n Linear -j 4

  # Also build a ModelArray-ready flat tree (one subfolder per scalar/param):
  $0 -i /data/local/134_AF19/derivatives/qsirecon/derivatives/qsirecon-NODDI \\
     -m /data/local/134_AF19/derivatives/modelarray/noddi
EOF
  exit 1
}

# ── Defaults ───────────────────────────────────────────────────────────────────
INPUT_DIR=""
OUTPUT_DIR=""
MODELARRAY_DIR=""
INTERP="Linear"
RES_TAG="01"
JOBS=1
FORCE=0

# ── Parse arguments ────────────────────────────────────────────────────────────
while getopts ":i:o:m:q:n:s:j:fh" opt; do
  case $opt in
    i) INPUT_DIR="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    m) MODELARRAY_DIR="$OPTARG" ;;
    q) QSIPREP_DIR="$OPTARG" ;;
    n) INTERP="$OPTARG" ;;
    s) RES_TAG="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    f) FORCE=1 ;;
    h) usage ;;
    \?) echo "ERROR: Invalid option -$OPTARG" >&2; usage ;;
    :)  echo "ERROR: Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# ── Validate required arguments ────────────────────────────────────────────────
if [[ -z "$INPUT_DIR" ]]; then
  echo "ERROR: -i is required." >&2
  usage
fi

# Resolve template from res tag or float mm value
RES_IS_FLOAT=0
if [[ "$RES_TAG" =~ ^[0-9]+\.[0-9]+$ || "$RES_TAG" =~ ^[0-9]+\.[0-9]*$ ]]; then
  RES_IS_FLOAT=1
fi

TEMPLATE_CUSTOM=""  # set when we resample on the fly

if [[ $RES_IS_FLOAT -eq 1 ]]; then
  # Float mm: use res-01 as base and resample below (after validation)
  TEMPLATE="${TEMPLATE_DIR}/${TEMPLATE_PREFIX}_res-01_T1w.nii.gz"
else
  TEMPLATE="${TEMPLATE_DIR}/${TEMPLATE_PREFIX}_res-${RES_TAG}_T1w.nii.gz"
fi

[[ -d "$INPUT_DIR" ]]   || { echo "ERROR: Input dir not found: $INPUT_DIR" >&2;  exit 1; }
[[ -d "$QSIPREP_DIR" ]] || { echo "ERROR: QSIPrep dir not found: $QSIPREP_DIR" >&2; exit 1; }
[[ -f "$TEMPLATE" ]]    || { echo "ERROR: Template not found: $TEMPLATE" >&2
                             echo "       Available templates:" >&2
                             ls "${TEMPLATE_DIR}/${TEMPLATE_PREFIX}_res-"*"_T1w.nii.gz" 2>/dev/null | sed 's/^/         /' >&2
                             exit 1; }

if [[ $RES_IS_FLOAT -eq 1 ]]; then
  command -v ResampleImageBySpacing >/dev/null 2>&1 \
    || { echo "ERROR: ResampleImageBySpacing (ANTs) not found — needed for float -s." >&2; exit 1; }
  TEMPLATE_CUSTOM="/tmp/tpl-MNI152NLin2009cAsym_res-custom_${RES_TAG}mm_T1w.nii.gz"
  echo "Resampling MNI res-01 template to ${RES_TAG}mm isotropic..."
  ResampleImageBySpacing 3 "$TEMPLATE" "$TEMPLATE_CUSTOM" \
    "$RES_TAG" "$RES_TAG" "$RES_TAG" 0
  TEMPLATE="$TEMPLATE_CUSTOM"
fi

# Read actual voxel size from the template file (truth, not assumption)
TEMPLATE_VOX=$(fslval "$TEMPLATE" pixdim1 2>/dev/null | xargs printf "%.4g") || TEMPLATE_VOX="unknown"

command -v antsApplyTransforms >/dev/null 2>&1 \
  || { echo "ERROR: antsApplyTransforms not found in PATH." >&2; exit 1; }

# If no output dir given, outputs go alongside inputs (OUTPUT_DIR stays empty)
[[ -n "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"
[[ -n "$MODELARRAY_DIR" ]] && mkdir -p "$MODELARRAY_DIR"

# ── Summary ────────────────────────────────────────────────────────────────────
echo "============================================================"
echo " ACPC → MNI152NLin2009cAsym Registration"
echo "============================================================"
echo " Input dir  : $INPUT_DIR"
echo " Output dir : $( [[ -n "$OUTPUT_DIR" ]] && echo "$OUTPUT_DIR" || echo "(same as input)")"
echo " ModelArray : $( [[ -n "$MODELARRAY_DIR" ]] && echo "$MODELARRAY_DIR" || echo "(not requested)")"
echo " QSIPrep    : $QSIPREP_DIR"
echo " Template   : $TEMPLATE"
if [[ $RES_IS_FLOAT -eq 1 ]]; then
  echo " Res tag    : custom ${RES_TAG}mm isotropic (resampled from res-01)"
else
  echo " Res tag    : res-${RES_TAG}  (voxel size: ${TEMPLATE_VOX} mm, read from file)"
fi
echo " Interpolation: $INTERP"
echo " Jobs       : $JOBS"
echo " Force      : $( [[ $FORCE -eq 1 ]] && echo yes || echo no )"
echo "============================================================"
echo ""

# ── Helper: derive output filename ────────────────────────────────────────────
# Replaces ACPC space labels with MNI152NLin2009cAsym in the filename.
# When resolution != 1mm, injects a res-Xmm BIDS tag into the filename.
make_mni_filename() {
  local fname="$1"
  local out
  local res_tag
  # Only inject a res tag when non-default; use the TemplateFlow tag verbatim
  # or the custom mm value for float mode — no mm assumptions.
  if [[ $RES_IS_FLOAT -eq 1 ]]; then
    res_tag="_res-${RES_TAG}mm"
  elif [[ "$RES_TAG" != "01" ]]; then
    res_tag="_res-${RES_TAG}"
  else
    res_tag=""
  fi

  # BIDS tag:  space-ACPC  →  space-MNI152NLin2009cAsym[_res-XX]
  if [[ "$fname" == *"space-ACPC"* ]]; then
    out="${fname/space-ACPC/space-MNI152NLin2009cAsym}"
    # inject res tag after the space entity
    out="${out/space-MNI152NLin2009cAsym/space-MNI152NLin2009cAsym${res_tag}}"

  # Simple suffix:  _ACPC.nii.gz  →  _MNI[_res-XX].nii.gz
  elif [[ "$fname" == *"_ACPC.nii.gz" ]]; then
    out="${fname/_ACPC.nii.gz/_MNI${res_tag}.nii.gz}"

  # Mid-name pattern:  _ACPC_  →  _MNI[_res-XX]_
  elif [[ "$fname" == *"_ACPC_"* ]]; then
    out="${fname/_ACPC_/_MNI${res_tag}_}"

  # Fallback: append _MNI[_res-XX] before extension
  else
    out="${fname%.nii.gz}_MNI${res_tag}.nii.gz"
  fi

  echo "$out"
}

# ── Core registration function ─────────────────────────────────────────────────
register_one() {
  local input_file="$1"
  local output_file="$2"
  local xfm_file="$3"

  mkdir -p "$(dirname "$output_file")"

  antsApplyTransforms \
    -i "$input_file" \
    -r "$TEMPLATE" \
    -t "$xfm_file" \
    -o "$output_file" \
    -n "$INTERP" \
    -v 0
}
export -f register_one
export TEMPLATE INTERP

# ── Build job list ─────────────────────────────────────────────────────────────
JOB_LIST=()
FOUND_SUBJECTS=0
FOUND_FILES=0
SKIP_COUNT=0

# Iterate over subjects that have a valid ACPC→MNI transform in QSIPrep
while IFS= read -r XFM_FILE; do
  # Derive subject ID from path: .../sub-XXXXX/anat/sub-XXXXX_from-ACPC_...
  SUBID=$(echo "$XFM_FILE" | grep -oP 'sub-[^/]+(?=/anat/)')

  SUB_INPUT="${INPUT_DIR}/${SUBID}"
  [[ -d "$SUB_INPUT" ]] || continue

  ((FOUND_SUBJECTS++)) || true

  # Search for ACPC NIfTI files under sub-/ses-/ (with optional dwi subfolder)
  while IFS= read -r ACPC_FILE; do
    # Determine output path mirroring the input structure
    REL_PATH="${ACPC_FILE#${INPUT_DIR}/}"          # e.g. sub-134001/ses-1/dwi/file_ACPC.nii.gz
    DIRNAME=$(dirname "$REL_PATH")
    BASENAME=$(basename "$ACPC_FILE")

    MNI_BASENAME=$(make_mni_filename "$BASENAME")
    if [[ -n "$OUTPUT_DIR" ]]; then
      OUTPUT_FILE="${OUTPUT_DIR}/${DIRNAME}/${MNI_BASENAME}"
    else
      OUTPUT_FILE="$(dirname "$ACPC_FILE")/${MNI_BASENAME}"
    fi

    if [[ -f "$OUTPUT_FILE" && $FORCE -eq 0 ]]; then
      echo "  [SKIP] $SUBID: $BASENAME (output exists)"
      ((SKIP_COUNT++)) || true
      continue
    fi

    ((FOUND_FILES++)) || true
    # Store as: "input_file|output_file|xfm_file"
    JOB_LIST+=("${ACPC_FILE}|${OUTPUT_FILE}|${XFM_FILE}")

  done < <(find "$SUB_INPUT" \
             -maxdepth 3 \
             -name "*.nii.gz" \
             \( -name "*space-ACPC*" -o -name "*_ACPC.nii.gz" -o -name "*_ACPC_*" \) \
           | sort)

done < <(find "$QSIPREP_DIR" \
           -name "sub-*_from-ACPC_to-MNI152NLin2009cAsym_mode-image_xfm.h5" \
         | sort)

echo "Subjects found in input : $FOUND_SUBJECTS"
echo "Files to process        : $FOUND_FILES"
echo "Files skipped (exist)   : $SKIP_COUNT"
echo ""

if [[ ${#JOB_LIST[@]} -eq 0 ]]; then
  echo "Nothing to do. Exiting."
  exit 0
fi

# ── Execute jobs ───────────────────────────────────────────────────────────────
PROCESSED=0
FAILED=0

run_job() {
  local entry="$1"
  local in_file out_file xfm_file
  IFS='|' read -r in_file out_file xfm_file <<< "$entry"

  local sub ses
  sub=$(echo "$in_file" | grep -oP 'sub-\d+')
  ses=$(echo "$in_file" | grep -oP 'ses-\d+' || echo "ses-?")
  local bn
  bn=$(basename "$in_file")

  echo "  [PROC] ${sub} ${ses}: ${bn}"

  if register_one "$in_file" "$out_file" "$xfm_file"; then
    echo "  [DONE] → $(basename "$out_file")"
    return 0
  else
    echo "  [FAIL] ${in_file}" >&2
    return 1
  fi
}
export -f run_job make_mni_filename

if [[ $JOBS -gt 1 ]] && command -v parallel >/dev/null 2>&1; then
  printf '%s\n' "${JOB_LIST[@]}" \
    | parallel --jobs "$JOBS" --halt soon,fail=1 run_job {}
  PROCESSED=${#JOB_LIST[@]}
else
  if [[ $JOBS -gt 1 ]]; then
    echo "WARNING: GNU parallel not found, running sequentially."
  fi
  for entry in "${JOB_LIST[@]}"; do
    if run_job "$entry"; then
      ((PROCESSED++)) || true
    else
      ((FAILED++)) || true
    fi
  done
fi

# ── ModelArray flat tree (symlinks) ───────────────────────────────────────────
if [[ -n "$MODELARRAY_DIR" ]]; then
  echo ""
  echo "Building ModelArray directory tree: $MODELARRAY_DIR"

  # Helper: extract scalar/param name from a NIfTI filename.
  # Priority: BIDS param-XXX tag → model-XXX tag → filename stem.
  extract_scalar_name() {
    local fname="$1"
    local name
    # BIDS param-XXX  (e.g. param-icvf)
    if name=$(echo "$fname" | grep -oP '(?<=param-)\w+' | head -1) && [[ -n "$name" ]]; then
      echo "$name"; return
    fi
    # BIDS model-XXX  (e.g. model-noddi)
    if name=$(echo "$fname" | grep -oP '(?<=model-)\w+' | head -1) && [[ -n "$name" ]]; then
      echo "$name"; return
    fi
    # Fallback: strip extension and common BIDS suffixes
    name="${fname%.nii.gz}"
    name="${name%%_space-*}"
    name="${name##*_}"
    echo "$name"
  }

  LINK_COUNT=0
  for entry in "${JOB_LIST[@]}"; do
    IFS='|' read -r _in mni_file _xfm <<< "$entry"
    bn=$(basename "$mni_file")
    scalar=$(extract_scalar_name "$bn")
    scalar_dir="${MODELARRAY_DIR}/${scalar}"
    mkdir -p "$scalar_dir"
    link="${scalar_dir}/${bn}"
    # Use absolute path for the symlink target
    abs_mni=$(realpath -m "$mni_file")
    if [[ ! -L "$link" || $FORCE -eq 1 ]]; then
      ln -sf "$abs_mni" "$link"
      ((LINK_COUNT++)) || true
    fi
  done

  echo "  Symlinks created: $LINK_COUNT"
  echo "  Scalars found   : $(ls "$MODELARRAY_DIR" | tr '\n' ' ')"
fi

# ── Final summary ──────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Done"
echo " Processed : $PROCESSED"
echo " Skipped   : $SKIP_COUNT"
echo " Failed    : $FAILED"
[[ -n "$MODELARRAY_DIR" ]] && echo " ModelArray : $MODELARRAY_DIR"
echo "============================================================"

[[ $FAILED -eq 0 ]] || exit 1
