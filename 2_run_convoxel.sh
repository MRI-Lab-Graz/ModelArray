#!/bin/bash

usage() {
 echo " Usage: $0 -c cohort_ISOVF.csv -r /data/study"
 exit 1
}

set -e  # Exit on error
set -o pipefail

# Initialize variables
COHORT_FILE=""
RELATIVE_ROOT=""

# Parse command-line options
#!/bin/bash

# Define debug function early
debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo -e "\033[1;36m[DEBUG] $*\033[0m"  # Optional: color for visibility
  fi
}

DEBUG=0  # Default; gets overridden by -d flag


while getopts ":c:r:d" opt; do
  case $opt in
    c) COHORT_FILE="$OPTARG" ;;
    r) RELATIVE_ROOT="$OPTARG" ;;
    d) DEBUG=1 ;;  # Enable debug mode
    \?) echo "Invalid option -$OPTARG" >&2
        exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2
       exit 1 ;;
  esac
done

# Check if required options are provided
if [[ -z "$COHORT_FILE" ]]; then
  echo "ERROR: Cohort file must be specified with -c option."
usage
  exit 1
fi
echo "Your cohort file: $COHORT_FILE"

if [[ -z "$RELATIVE_ROOT" ]]; then
  echo "ERROR: Relative root directory must be specified with -r option."
usage
  exit 1
fi
debug "Your root folder: $RELATIVE_ROOT"
# Construct the full path to the group mask
GROUP_MASK="${RELATIVE_ROOT}/group_mask.nii.gz"

debug "Group mask is located at: $GROUP_MASK"

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
BASE_COHORT=$(basename "$COHORT_FILE" .csv)
OUTPUT_HDF5="${BASE_COHORT}_${SCALAR_NAME}.h5"

echo "Detected scalar: $SCALAR_NAME"
echo "Output will be written to: $OUTPUT_HDF5"

# Get group mask dimensions
GROUP_DIM=$(mrinfo "$GROUP_MASK" -quiet -size | tr -d '\n')
echo "Group mask dimension: $GROUP_DIM"

# Check each row in the cohort for existence and matching dimensions
echo "Validating cohort files..."
while IFS=',' read -r SCALAR FILE MASK_FILE SUBJECT_ID REST; do
  debug "---"
  debug "[DEBUG] SCALAR=$SCALAR, FILE=$FILE, MASK_FILE=$MASK_FILE, SUBJECT_ID=$SUBJECT_ID"
  FULL_OD="${RELATIVE_ROOT}/${FILE}"
  FULL_MASK="${RELATIVE_ROOT}/${MASK_FILE}"
  debug "[CHECKPOINT] Checking files for $SUBJECT_ID"
  debug "  OD: $FULL_OD"
  debug "  MASK: $FULL_MASK"

  if [[ ! -f "$FULL_OD" ]]; then
    echo "❌ ERROR: Missing source file: $FULL_OD"
    exit 1
  fi
  if [[ ! -f "$FULL_MASK" ]]; then
    echo "❌ ERROR: Missing mask file: $FULL_MASK"
    exit 1
  fi

  OD_DIM=$(mrinfo "$FULL_OD" -quiet -size | tr -d '\n')
  MASK_DIM=$(mrinfo "$FULL_MASK" -quiet -size | tr -d '\n')

  debug "[DEBUG] OD_DIM=$OD_DIM, MASK_DIM=$MASK_DIM"

  if [[ "$OD_DIM" != "$GROUP_DIM" ]]; then
    echo "❌ ERROR: Dimension mismatch for OD file ($SUBJECT_ID)"
    exit 1
  fi
  if [[ "$MASK_DIM" != "$GROUP_DIM" ]]; then
    echo "❌ ERROR: Dimension mismatch for MASK file ($SUBJECT_ID)"
    exit 1
  fi
done < <(tail -n +2 "$COHORT_FILE")

echo "All files validated successfully. Starting modelarray..."

singularity run --cleanenv -B "$RELATIVE_ROOT":"$RELATIVE_ROOT" \
  /data/local/container/modelarray/modelarray_confixel_0.1.5.sif \
  convoxel \
    --group-mask-file "$GROUP_MASK" \
    --cohort-file "$COHORT_FILE" \
    --relative-root "$RELATIVE_ROOT" \
    --output-hdf5 "$OUTPUT_HDF5"

echo "✅ Done: $OUTPUT_HDF5 created"
