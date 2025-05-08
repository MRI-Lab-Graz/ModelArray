#!/bin/bash

# Usage: ./run_from_json.sh /path/to/config.json

CONFIG_PATH="$1"
if [ ! -f "$CONFIG_PATH" ]; then
  echo "🛑 Config file not found: $CONFIG_PATH"
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

# Volumestats export fields
GROUP_MASK=$(get_json_value '.group_mask_file')
OUTPUT_DIR=$(get_json_value '.output_dir')
OUTPUT_EXT=$(get_json_value '.output_ext')

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
# Continue with the rest of the R script
cat >> "$R_SCRIPT_PATH" <<EOF


formula <- $FORMULA

mylm <- ModelArray.lm(
  formula = formula,
  data = modelarray,
  phenotypes = phenotypes,
  scalar = "$SCALER_TYPE",
  num.subj.lthr.abs = $NUM_ABS,
  num.subj.lthr.rel = $NUM_REL,
  full.outputs = $FULL_OUTPUTS,
  n_cores = $N_CORES,
  verbose = TRUE
)

writeResults(h5_path, df.output = mylm, analysis_name = "$ANALYSIS_NAME")

summary_df <- summary(mylm)
write.csv(summary_df, file = "/data/$CSV_SUMMARY", row.names = FALSE)
print(colnames(summary_df))
EOF

echo "✅ R script generated at: $R_SCRIPT_PATH"

# Run the model analysis
singularity run --cleanenv -B "$DATA_DIR:/data" \
  "$CONTAINER" Rscript /data/$(basename "$R_SCRIPT_PATH")

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
  --output-ext "$OUTPUT_EXT"

echo "✅ All steps completed successfully."
