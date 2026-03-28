#!/bin/bash
# Generate a ModelArray cohort CSV for longitudinal (multi-session) data.
#
# Matches participant_id (e.g. sub-134001_ses-1) from the participants TSV
# to the corresponding NIfTI file in the scalar folder, creating one row
# per subject-session. Works directly with the output of 0_register_acpc_to_mni.sh.
#
# Usage:
#   ./1_generate_cohort_longitudinal.sh -p participants_longitudinal.tsv \
#       -d /path/to/scalar_folder -m /path/to/mask_folder -o output_folder

set -e
set -o pipefail

usage() {
  cat <<EOF
Usage: $0 -p PARTICIPANTS_TSV -d NII_FOLDER -m MASK_FOLDER -o OUTPUT_FOLDER

Required:
  -p  Longitudinal participants TSV (one row per subject-session)
        Must have a 'participant_id' column of the form sub-XXXXXX_ses-N
  -d  Scalar NIfTI folder (flat, all sessions in one folder)
        e.g. modellarray/noddi/icvf_dwimap/
  -m  Brain mask folder (same layout as NIfTI folder, or same folder)
  -o  Output folder for the cohort CSV

Optional:
  -s  Subgroup filter  COLUMN:VALUE  (e.g. group:1)
  -h  Show this help

Example:
  $0 -p /data/local/134_AF19/derivatives/modelarray/participants_longitudinal.tsv \\
     -d /data/local/134_AF19/derivatives/modelarray/noddi/icvf_dwimap \\
     -m /data/local/134_AF19/derivatives/modelarray/noddi/icvf_dwimap \\
     -o /data/local/134_AF19/derivatives/modelarray/noddi
EOF
  exit 1
}

# ── Defaults ───────────────────────────────────────────────────────────────────
PARTICIPANTS_FILE=""
NII_FOLDER=""
MASK_FOLDER=""
OUTPUT_FOLDER="."
SUBGROUP=""
COLUMN=""
VALUE=""

while [[ "$#" -gt 0 ]]; do
  case $1 in
    -p|--participants) PARTICIPANTS_FILE="$2"; shift 2 ;;
    -d|--data-dir)     NII_FOLDER="$2";        shift 2 ;;
    -m|--mask)         MASK_FOLDER="$2";       shift 2 ;;
    -o|--output)       OUTPUT_FOLDER="$2";     shift 2 ;;
    -s|--subgroup)
      SUBGROUP="$2"
      COLUMN="${SUBGROUP%%:*}"
      VALUE="${SUBGROUP##*:}"
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
done

# ── Validate ───────────────────────────────────────────────────────────────────
[[ -z "$PARTICIPANTS_FILE" || -z "$NII_FOLDER" || -z "$MASK_FOLDER" ]] && {
  echo "ERROR: -p, -d, and -m are required." >&2; usage; }
[[ -f "$PARTICIPANTS_FILE" ]] || { echo "ERROR: Not found: $PARTICIPANTS_FILE" >&2; exit 1; }
[[ -d "$NII_FOLDER" ]]        || { echo "ERROR: Not found: $NII_FOLDER" >&2;        exit 1; }
[[ -d "$MASK_FOLDER" ]]       || { echo "ERROR: Not found: $MASK_FOLDER" >&2;       exit 1; }

mkdir -p "$OUTPUT_FOLDER"

# ── Optional subgroup filter ───────────────────────────────────────────────────
if [[ -n "$SUBGROUP" ]]; then
  FILTERED=$(mktemp)
  awk -v col="$COLUMN" -v val="$VALUE" '
    BEGIN { FS="\t"; OFS="\t" }
    NR==1 {
      for (i=1; i<=NF; i++) if ($i==col) colnum=i
      if (!colnum) { print "ERROR: column " col " not found" > "/dev/stderr"; exit 1 }
      print; next
    }
    $colnum == val { print }
  ' "$PARTICIPANTS_FILE" > "$FILTERED"
  PARTICIPANTS_FILE="$FILTERED"
fi

# ── Derive scalar name from folder name ───────────────────────────────────────
SCALAR_NAME=$(basename "$NII_FOLDER")

# ── Extra phenotype columns (everything after participant_id) ─────────────────
HEADER=$(head -n 1 "$PARTICIPANTS_FILE")
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"
EXTRA_COLS=$(IFS=','; echo "${COLUMNS[*]:1}")   # all cols except participant_id

# ── Output file ───────────────────────────────────────────────────────────────
if [[ -n "$SUBGROUP" ]]; then
  SUFFIX="_${COLUMN}-${VALUE}"
else
  SUFFIX=""
fi
OUTPUT_FILE="${OUTPUT_FOLDER}/cohort_${SCALAR_NAME}${SUFFIX}.csv"

echo "scalar_name,source_file,source_mask_file,subject_id,${EXTRA_COLS}" > "$OUTPUT_FILE"

# ── Match rows → NIfTI files ──────────────────────────────────────────────────
MATCHED=0
MISSING=0

while IFS=$'\t' read -r -a LINE; do
  PARTICIPANT_ID="${LINE[0]}"    # e.g. sub-134001_ses-1

  # Extract sub-XXXXXX and ses-N for targeted file matching
  SUB=$(echo "$PARTICIPANT_ID" | grep -oP '^sub-\d+')
  SES=$(echo "$PARTICIPANT_ID" | grep -oP 'ses-\d+$')

  # Find the NIfTI for this exact subject+session
  NII_FILE=$(find "$NII_FOLDER" -maxdepth 1 -name "${SUB}_${SES}*.nii.gz" | head -n 1)
  MASK_FILE=$(find "$MASK_FOLDER" -maxdepth 1 -name "${SUB}_${SES}*.nii.gz" | head -n 1)

  # Fallback: if mask folder has only one mask (e.g. group brain mask), use it
  if [[ -z "$MASK_FILE" ]]; then
    MASK_FILE=$(find "$MASK_FOLDER" -maxdepth 1 -name "*.nii.gz" | head -n 1)
  fi

  if [[ -z "$NII_FILE" ]]; then
    echo "  WARNING: No NIfTI found for ${PARTICIPANT_ID}" >&2
    ((MISSING++)) || true
    continue
  fi

  SHORT_NII="${SCALAR_NAME}/$(basename "$NII_FILE")"
  SHORT_MASK="${SCALAR_NAME}/$(basename "$MASK_FILE")"

  METADATA=$(IFS=','; printf "%s" "${LINE[*]:1}")
  printf "%s,%s,%s,%s,%s\n" \
    "$SCALAR_NAME" "$SHORT_NII" "$SHORT_MASK" "$PARTICIPANT_ID" "$METADATA" \
    >> "$OUTPUT_FILE"
  ((MATCHED++)) || true

done < <(tail -n +2 "$PARTICIPANTS_FILE")

echo "============================================================"
echo " Cohort file : $OUTPUT_FILE"
echo " Matched     : $MATCHED rows"
echo " Missing     : $MISSING rows"
echo "============================================================"
echo ""
echo "Preview (first 4 data rows):"
head -5 "$OUTPUT_FILE"
