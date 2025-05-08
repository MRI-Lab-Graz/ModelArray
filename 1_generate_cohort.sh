#!/bin/bash

# Usage: ./generate_cohort.sh -p participants.tsv -d NII_folder -m mask_folder [-o output_folder]

usage() {
  echo "Usage: $0 -p participants.tsv -d NII_folder -m mask_folder [-o output_folder]"
  exit 1
}

# Parse arguments
while getopts ":p:d:m:o:" opt; do
  case ${opt} in
    p ) PARTICIPANTS_FILE="$OPTARG"
      ;;
    d ) NII_FOLDER="$OPTARG"
      ;;
    m ) MASK_FOLDER="$OPTARG"
      ;;
    o ) OUTPUT_FOLDER="$OPTARG"
      ;;
    \? )
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    : )
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

# Check required arguments
if [[ -z "$PARTICIPANTS_FILE" || -z "$NII_FOLDER" || -z "$MASK_FOLDER" ]]; then
  echo "Missing required arguments."
  usage
fi

# Set default output folder if not specified
OUTPUT_FOLDER="${OUTPUT_FOLDER:-.}"
mkdir -p "$OUTPUT_FOLDER"

# Extract header
HEADER=$(head -n 1 "$PARTICIPANTS_FILE")
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"
EXTRA_COLS=$(IFS=','; echo "${COLUMNS[*]:1}")

# Find scalar name
FIRST_NII_FILE=$(find "$NII_FOLDER" -type f -name "*.nii.gz" | head -n 1)
if [[ -z "$FIRST_NII_FILE" ]]; then
  echo "No Nifit file found in $NII_FOLDER"
  exit 1
fi
SCALAR_NAME=$(basename "$(dirname "$FIRST_NII_FILE")")
OUTPUT_FILE="$OUTPUT_FOLDER/cohort_${SCALAR_NAME}.csv"

echo "scalar_name,source_file,source_mask_file,subject_id,$EXTRA_COLS" > "$OUTPUT_FILE"

REF_DIM=""
REF_SUBJECT=""

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
      exit 1
    fi

    if [[ -z "$REF_DIM" ]]; then
      REF_DIM="$NII_DIM"
      REF_SUBJECT="$SUBJECT_SHORT"
    elif [[ "$NII_DIM" != "$REF_DIM" ]]; then
      echo "ERROR: Dimension mismatch with reference subject $REF_SUBJECT"
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
