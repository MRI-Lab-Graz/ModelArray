#!/bin/bash

# Usage: ./generate_cohort.sh participants.tsv OD_folder mask_folder

PARTICIPANTS_FILE="$1"
OD_FOLDER="$2"
MASK_FOLDER="$3"

if [[ ! -f "$PARTICIPANTS_FILE" || ! -d "$OD_FOLDER" || ! -d "$MASK_FOLDER" ]]; then
  echo "Usage: $0 participants.tsv OD_folder mask_folder"
  exit 1
fi

# Read header from participants.tsv to extract extra columns
HEADER=$(head -n 1 "$PARTICIPANTS_FILE")
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"

# Prepare output header line with proper comma separation
EXTRA_COLS=$(IFS=','; echo "${COLUMNS[*]:1}")

# Probe a file to determine scalar name (from OD folder name)
FIRST_OD_FILE=$(find "$OD_FOLDER" -type f -name "*.nii.gz" | head -n 1)
if [[ -z "$FIRST_OD_FILE" ]]; then
  echo "No OD file found in $OD_FOLDER"
  exit 1
fi

SCALAR_NAME=$(basename "$(dirname "$FIRST_OD_FILE")")
OUTPUT_FILE="cohort_${SCALAR_NAME}.csv"

# Write header to output file
echo "scalar_name,source_file,source_mask_file,subject_id,$EXTRA_COLS" > "$OUTPUT_FILE"

# To store reference dimensions
REF_DIM=""
REF_SUBJECT=""

# Read participants line by line
tail -n +2 "$PARTICIPANTS_FILE" | while IFS=$'\t' read -r -a LINE; do
  SUBJECT_ID="${LINE[0]}"
  SUBJECT_SHORT=$(echo "$SUBJECT_ID" | cut -d'_' -f1)

  OD_FILE=$(find "$OD_FOLDER" -type f -name "${SUBJECT_SHORT}*.nii.gz" | head -n 1)
  MASK_FILE=$(find "$MASK_FOLDER" -type f -name "${SUBJECT_SHORT}*.nii.gz" | head -n 1)

  if [[ -f "$OD_FILE" && -f "$MASK_FILE" ]]; then
    OD_DIM=$(mrinfo "$OD_FILE" -quiet -size | tr -d '\n')
    MASK_DIM=$(mrinfo "$MASK_FILE" -quiet -size | tr -d '\n')

    if [[ "$OD_DIM" != "$MASK_DIM" ]]; then
      echo "ERROR: Dimension mismatch between OD and mask for subject $SUBJECT_SHORT"
      echo "  OD file:    $OD_FILE"
      echo "  Mask file:  $MASK_FILE"
      echo "  OD dim:     $OD_DIM"
      echo "  Mask dim:   $MASK_DIM"
      exit 1
    fi

    if [[ -z "$REF_DIM" ]]; then
      REF_DIM="$OD_DIM"
      REF_SUBJECT="$SUBJECT_SHORT"
    elif [[ "$OD_DIM" != "$REF_DIM" ]]; then
      echo "ERROR: Dimension mismatch with reference subject $REF_SUBJECT"
      echo "  Current subject: $SUBJECT_SHORT"
      echo "  Current dim:     $OD_DIM"
      echo "  Reference dim:   $REF_DIM"
      echo "  OD file:         $OD_FILE"
      exit 1
    fi

    SHORT_OD=$(basename "$(dirname "$OD_FILE")")/$(basename "$OD_FILE")
    SHORT_MASK=$(basename "$(dirname "$MASK_FILE")")/$(basename "$MASK_FILE")

    METADATA=$(IFS=','; echo "${LINE[*]:1}")
    echo "$SCALAR_NAME,$SHORT_OD,$SHORT_MASK,$SUBJECT_SHORT,$METADATA" >> "$OUTPUT_FILE"
  else
    echo "WARNING: Missing OD or mask file for $SUBJECT_SHORT"
  fi
done

echo "Cohort file created: $OUTPUT_FILE"
