#!/bin/bash

# Usage: ./run_from_json.sh /path/to/config.json --test

TEST_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            TEST_MODE=true
            shift
            ;;
        *)
            CONFIG_PATH="$1"
            shift
            ;;
    esac
done

if [ -z "$CONFIG_PATH" ]; then
    echo "Usage: $0 [--test] /path/to/config.json"
    exit 1
fi

# Function to extract values from JSON
get_json_value() {
  jq -r "$1" "$CONFIG_PATH"
}

# Extract values from config
DATA_DIR=$(get_json_value '.data_dir')
CONTAINER=$(get_json_value '.container')
H5_FILE=$(get_json_value '.h5_file')
CSV_FILE=$(get_json_value '.csv_file')
SCALER_TYPE=$(get_json_value '.scaler_type')
FORMULA=$(get_json_value '.formula')
NUM_ABS=$(get_json_value '.num_subj_lthr_abs')
NUM_REL=$(get_json_value '.num_subj_lthr_rel')
FULL_OUTPUTS=$(get_json_value '.full_outputs' | tr '[:lower:]' '[:upper:]')
N_CORES=$(get_json_value '.n_cores')
ANALYSIS_NAME=$(get_json_value '.analysis_name')
CSV_SUMMARY=$(get_json_value '.csv_summary_path')
MODEL_TYPE=$(get_json_value '.model_type')  # New JSON tag for model type


# Volumestats export fields
GROUP_MASK=$(get_json_value '.group_mask_file')
OUTPUT_DIR=$(get_json_value '.output_dir')
OUTPUT_EXT=$(get_json_value '.output_ext')
# Ensure extension starts with a dot (nibabel requires e.g. ".nii.gz" not "nii.gz")
[[ "$OUTPUT_EXT" != .* ]] && OUTPUT_EXT=".${OUTPUT_EXT}"

# New fields for scaling and factorization
CONTINUOUS_COVARIATES=$(get_json_value '.continuous_covariates | join(" ")')
CATEGORICAL_VARIABLES=$(get_json_value '.categorical_variables | join(" ")')


# Validate required files
REQUIRED_FILES=(
  "$CONTAINER"
  "$DATA_DIR/$H5_FILE"
  "$DATA_DIR/$CSV_FILE"
  "$DATA_DIR/$GROUP_MASK"
)

MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "❌ Missing file: $file"
    MISSING=1
  fi
done

if [ "$MISSING" -eq 1 ]; then
  echo "🛑 One or more required files are missing. Aborting."
  exit 1
fi

# Validate MODEL_TYPE
if [[ "$MODEL_TYPE" != "lm" && "$MODEL_TYPE" != "gam" ]]; then
  echo "🛑 Invalid model type: $MODEL_TYPE. Must be 'lm' or 'gam'."
  exit 1
fi

# ✨ Rewrite formula
FINAL_FORMULA="$FORMULA"

# Replace continuous covariates with _DM
for covariate in $CONTINUOUS_COVARIATES; do
  FINAL_FORMULA=$(echo "$FINAL_FORMULA" | sed "s/\\b$covariate\\b/${covariate}_DM/g")
done

# Replace categorical variables with _F
for variable in $CATEGORICAL_VARIABLES; do
  FINAL_FORMULA=$(echo "$FINAL_FORMULA" | sed "s/\\b$variable\\b/${variable}_F/g")
done

# Generate R script dynamically
R_SCRIPT_PATH="$DATA_DIR/generated_script.R"

cat > "$R_SCRIPT_PATH" <<EOF
library(ModelArray)

h5_path <- "/data/$H5_FILE"
csv_path <- "/data/$CSV_FILE"
modelarray <- ModelArray(h5_path, scalar_types = c("$SCALER_TYPE"))
phenotypes <- read.csv(csv_path)

# Demean and center continuous covariates
EOF

# Add scaling for continuous covariates
if [ -n "$CONTINUOUS_COVARIATES" ]; then
for covariate in $CONTINUOUS_COVARIATES; do
  cat >> "$R_SCRIPT_PATH" <<EOF
${covariate}_demean <- scale(phenotypes\$${covariate})
phenotypes\$${covariate}_DM <- ${covariate}_demean
EOF
done
fi

# Add factorization for categorical variables
cat >> "$R_SCRIPT_PATH" <<EOF

# Convert categorical variables to factors
EOF

if [ -n "$CATEGORICAL_VARIABLES" ]; then
for variable in $CATEGORICAL_VARIABLES; do
  cat >> "$R_SCRIPT_PATH" <<EOF
phenotypes\$${variable}_F <- factor(phenotypes\$${variable})
EOF
done
fi

# Always add a numeric participant index for random-effect smooth s(participant_idx, bs='re')
cat >> "$R_SCRIPT_PATH" <<EOF
# Numeric subject index for random-effect smooth (mgcv bs='re' requires numeric)
phenotypes\$participant_idx <- as.integer(factor(phenotypes\$participant))
EOF
# Continue with the rest of the R script
cat >> "$R_SCRIPT_PATH" <<EOF


# Use rewritten formula
formula <- as.formula("$FINAL_FORMULA")

# ── Progress helpers ──────────────────────────────────────────────────────────
ts <- function(msg) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), msg))
  flush.console()
}

n_elements <- nrow(rhdf5::h5read(h5_path, "scalars/${SCALER_TYPE}/values"))
ts(sprintf("Starting ${MODEL_TYPE} on %s: %d elements, %d cores", "$SCALER_TYPE", n_elements, $N_CORES))

t_start <- proc.time()

# Heartbeat: print a timestamp every 30 s so you can tell it's still alive
heartbeat <- parallel::mcparallel({
  repeat { Sys.sleep(30); cat(sprintf("[%s] Still fitting...\n", format(Sys.time(), "%H:%M:%S"))); flush.console() }
})

mylm <- ModelArray.${MODEL_TYPE}(
  formula = formula,
  data = modelarray,
  phenotypes = phenotypes,
  scalar = "$SCALER_TYPE",
  num.subj.lthr.abs = $NUM_ABS,
  num.subj.lthr.rel = $NUM_REL,
  full.outputs = $FULL_OUTPUTS,
  n_cores = $N_CORES,
  verbose = TRUE,
  pbar = TRUE
)

tools::pskill(heartbeat\$pid, signal = 15L)  # stop heartbeat

elapsed <- proc.time() - t_start
ts(sprintf("Fitting done in %.1f min (%.0f elements/sec)",
           elapsed["elapsed"] / 60,
           n_elements / elapsed["elapsed"]))

ts("Writing results to HDF5...")
writeResults(h5_path, df.output = mylm, analysis_name = "$ANALYSIS_NAME")
ts("Done writing HDF5.")

summary_df <- summary(mylm)
write.csv(summary_df, file = "/data/$CSV_SUMMARY", row.names = FALSE)
print(colnames(summary_df))
EOF

echo "✅ R script generated at: $R_SCRIPT_PATH"

# If in test mode, just show the script and exit
if [ "$TEST_MODE" = true ]; then
    echo "=== TEST MODE: Showing R script content ==="
    cat "$R_SCRIPT_PATH"
    exit 0
fi

# Ensure output directories exist before R tries to write into them
mkdir -p "$DATA_DIR/$OUTPUT_DIR"
mkdir -p "$(dirname "$DATA_DIR/$CSV_SUMMARY")"

# Log file — always written alongside the data; tail -f it in another terminal
LOG_FILE="$DATA_DIR/modelarray_run_$(date +%Y%m%d_%H%M%S).log"
echo "📋 Log file: $LOG_FILE  (tail -f $LOG_FILE)"

# Run the model analysis — tee output to log and terminal simultaneously
singularity run --cleanenv -B "$DATA_DIR:/data" \
  "$CONTAINER" Rscript /data/$(basename "$R_SCRIPT_PATH") 2>&1 | tee "$LOG_FILE"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "🛑 Model analysis failed. See log: $LOG_FILE"
  exit 1
fi

# Write results to NIfTI
echo "📦 Writing output NIfTI files..."
singularity run --cleanenv -B "$DATA_DIR:/data" \
  "$CONTAINER" volumestats_write \
  --group-mask-file "/data/$GROUP_MASK" \
  --cohort-file "/data/$CSV_FILE" \
  --relative-root /data \
  --analysis-name "$ANALYSIS_NAME" \
  --input-hdf5 "/data/$H5_FILE" \
  --output-dir "/data/$OUTPUT_DIR" \
  --output-ext "$OUTPUT_EXT" 2>&1 | tee -a "$LOG_FILE"

echo "✅ All steps completed successfully. Full log: $LOG_FILE"
