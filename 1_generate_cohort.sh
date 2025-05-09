#!/bin/bash

usage() {
  echo "Usage: $0 -p participants.tsv -d NII_folder -m mask_folder -o output_folder [-s subgroup:value]"
  exit 1
}

# Default values
SUBGROUP=""
COLUMN=""
VALUE=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--subgroup)
            SUBGROUP="$2"
            COLUMN="${SUBGROUP%%:*}"
            VALUE="${SUBGROUP##*:}"
            shift 2
            ;;
        # add any other arguments you already support here
        -p|--participants)
            PARTICIPANTS_FILE="$2"
            shift 2
            ;;
        -d|--data-dir)
            NII_FOLDER="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FOLDER="$2"
            shift 2
            ;;
        -m|--mask)
            MASK_FOLDER="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter passed: $1"
            exit 1
            ;;
    esac
done


# Prepare filtered participants file if subgrouping is requested
if [[ -n "$SUBGROUP" ]]; then
    FILTERED_PARTICIPANTS=$(mktemp)
    awk -v col="$COLUMN" -v val="$VALUE" '
    BEGIN { FS="\t"; OFS="\t" }
    NR==1 {
        for (i=1; i<=NF; i++) {
            if ($i == col) colnum=i;
        }
        if (!colnum) {
            print "Error: Column " col " not found in header" > "/dev/stderr";
            exit 1;
        }
        print;
    }
    NR>1 {
        if ($colnum == val) print;
    }
    ' "$PARTICIPANTS_FILE" > "$FILTERED_PARTICIPANTS"
    PARTICIPANTS_FILE="$FILTERED_PARTICIPANTS"
    OUTPUT="${OUTPUT%.tsv}_${COLUMN}-${VALUE}.tsv"
fi

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
echo "Showing the head to double-check"
head $OUTPUT_FILE
