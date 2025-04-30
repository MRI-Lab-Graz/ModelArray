#!/bin/bash

# Usage: ./generate_cohort.sh participants.tsv NII_folder mask_folder

PARTICIPANTS_FILE="$1"
NII_FOLDER="$2"
MASK_FOLDER="$3"

if [[ ! -f "$PARTICIPANTS_FILE" || ! -d "$NII_FOLDER" || ! -d "$MASK_FOLDER" ]]; then
  echo "Usage: $0 participants.tsv NII_folder mask_folder"
  exit 1
fi

# Read header from participants.tsv to extract extra columns
HEADER=$(head -n 1 "$PARTICIPANTS_FILE")
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"

# Prepare output header line with proper comma separation
EXTRA_COLS=$(IFS=','; echo "${COLUMNS[*]:1}")

# Probe a file to determine scalar name (from Nifit folder name)
FIRST_NII_FILE=$(find "$NII_FOLDER" -type f -name "*.nii.gz" | head -n 1)
if [[ -z "$FIRST_NII_FILE" ]]; then
  echo "No Nifit file found in $NII_FOLDER"
  exit 1
fi

SCALAR_NAME=$(basename "$(dirname "$FIRST_NII_FILE")")
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

  NII_FILE=$(find "$NII_FOLDER" -type f -name "${SUBJECT_SHORT}*.nii.gz" | head -n 1)
  MASK_FILE=$(find "$MASK_FOLDER" -type f -name "${SUBJECT_SHORT}*.nii.gz" | head -n 1)

  if [[ -f "$NII_FILE" && -f "$MASK_FILE" ]]; then
    NII_DIM=$(mrinfo "$NII_FILE" -quiet -size | tr -d '\n')
    MASK_DIM=$(mrinfo "$MASK_FILE" -quiet -size | tr -d '\n')

    if [[ "$NII_DIM" != "$MASK_DIM" ]]; then
      echo "ERROR: Dimension mismatch between Nifit and mask for subject $SUBJECT_SHORT"
      echo "  Nifit file:    $NII_FILE"
      echo "  Mask file:  $MASK_FILE"
      echo "  Nifit dim:     $NII_DIM"
      echo "  Mask dim:   $MASK_DIM"
      exit 1
    fi

    if [[ -z "$REF_DIM" ]]; then
      REF_DIM="$NII_DIM"
      REF_SUBJECT="$SUBJECT_SHORT"
    elif [[ "$NII_DIM" != "$REF_DIM" ]]; then
      echo "ERROR: Dimension mismatch with reference subject $REF_SUBJECT"
      echo "  Current subject: $SUBJECT_SHORT"
      echo "  Current dim:     $NII_DIM"
      echo "  Reference dim:   $REF_DIM"
      echo "  NII file:         $NII_FILE"
      exit 1
    fi

    SHORT_NII=$(basename "$(dirname "$NII_FILE")")/$(basename "$NII_FILE")
    SHORT_MASK=$(basename "$(dirname "$MASK_FILE")")/$(basename "$MASK_FILE")

    METADATA=$(IFS=','; echo "${LINE[*]:1}")
    echo "$SCALAR_NAME,$SHORT_NII,$SHORT_MASK,$SUBJECT_SHORT,$METADATA" >> "$OUTPUT_FILE"
  else
    echo "WARNING: Missing Nifit or mask file for $SUBJECT_SHORT"
  fi
done

echo "Cohort file created: $OUTPUT_FILE"
