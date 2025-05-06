#!/bin/bash

# Usage: ./run_modelarray.sh -c cohort_ISOVF.csv -r /data/study

set -e  # Exit on error
set -o pipefail

# Initialize variables
COHORT_FILE=""
RELATIVE_ROOT=""

# Parse command-line options
while getopts ":c:r:" opt; do
  case $opt in
    c) COHORT_FILE="$OPTARG" ;;
    r) RELATIVE_ROOT="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2
        exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2
       exit 1 ;;
  esac
done

# Check if required options are provided
if [[ -z "$COHORT_FILE" ]]; then
  echo "ERROR: Cohort file must be specified with -c option."
  exit 1
fi

if [[ -z "$RELATIVE_ROOT" ]]; then
  echo "ERROR: Relative root directory must be specified with -r option."
  exit 1
fi

# Construct the full path to the group mask
GROUP_MASK="${RELATIVE_ROOT}/group_mask.nii.gz"


if [[ ! -f "$COHORT_FILE" ]]; then
  echo "ERROR: Cohort file not found: $COHORT_FILE"
  exit 1
fi

if [[ ! -f "$GROUP_MASK" ]]; then
  echo "ERROR: Group mask file not found: $GROUP_MASK"
  exit 1
fi

# Extract scalar name from first line (excluding header)
SCALAR_NAME=$(tail -n +2 "$COHORT_FILE" | head -n 1 | cut -d',' -f1)
OUTPUT_HDF5="${SCALAR_NAME}.h5"

echo "Detected scalar: $SCALAR_NAME"
echo "Output will be written to: $OUTPUT_HDF5"

# Get group mask dimensions
GROUP_DIM=$(mrinfo "$GROUP_MASK" -quiet -size | tr -d '\n')
echo "Group mask dimension: $GROUP_DIM"

# Check each row in the cohort for existence and matching dimensions
echo "Validating cohort files..."
tail -n +2 "$COHORT_FILE" | while IFS=',' read -r SCALAR FILE MASK_FILE SUBJECT_ID REST; do
  FULL_OD="${RELATIVE_ROOT}/${FILE}"
  FULL_MASK="${RELATIVE_ROOT}/${MASK_FILE}"

  # Check files exist
  if [[ ! -f "$FULL_OD" ]]; then
    echo "ERROR: Missing source file: $FULL_OD"
    exit 1
  fi
  if [[ ! -f "$FULL_MASK" ]]; then
    echo "ERROR: Missing mask file: $FULL_MASK"
    exit 1
  fi

  # Check dimensions
  OD_DIM=$(mrinfo "$FULL_OD" -quiet -size | tr -d '\n')
  MASK_DIM=$(mrinfo "$FULL_MASK" -quiet -size | tr -d '\n')

  if [[ "$OD_DIM" != "$GROUP_DIM" ]]; then
    echo "ERROR: Dimension mismatch for OD file ($SUBJECT_ID)"
    echo "  File: $FULL_OD"
    echo "  File dim: $OD_DIM"
    echo "  Group dim: $GROUP_DIM"
    exit 1
  fi

  if [[ "$MASK_DIM" != "$GROUP_DIM" ]]; then
    echo "ERROR: Dimension mismatch for MASK file ($SUBJECT_ID)"
    echo "  File: $FULL_MASK"
    echo "  File dim: $MASK_DIM"
    echo "  Group dim: $GROUP_DIM"
    exit 1
  fi
done

echo "All files validated successfully. Starting modelarray..."

singularity run --cleanenv -B "$RELATIVE_ROOT":"$RELATIVE_ROOT" \
  /data/local/container/modelarray/modelarray_confixel_0.1.5.sif \
  convoxel \
    --group-mask-file "$GROUP_MASK" \
    --cohort-file "$COHORT_FILE" \
    --relative-root "$RELATIVE_ROOT" \
    --output-hdf5 "$OUTPUT_HDF5"

echo "✅ Done: $OUTPUT_HDF5 created"
