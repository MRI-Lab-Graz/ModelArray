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

get_json_compact() {
  jq -c "$1" "$CONFIG_PATH"
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
ELEMENT_SUBSET_JSON=$(get_json_compact '.element_subset // null')
ELEMENT_RANGE_JSON=$(get_json_compact '.element_range // null')
MODEL_OPTIONS_JSON=$(get_json_compact '.model_options // {}')


# Volumestats export fields
GROUP_MASK=$(get_json_value '.group_mask_file')
OUTPUT_DIR=$(get_json_value '.output_dir')
OUTPUT_EXT=$(get_json_value '.output_ext')
# Ensure extension starts with a dot (nibabel requires e.g. ".nii.gz" not "nii.gz")
[[ "$OUTPUT_EXT" != .* ]] && OUTPUT_EXT=".${OUTPUT_EXT}"

# New fields for scaling and factorization
CONTINUOUS_COVARIATES=$(get_json_value '.continuous_covariates | join(" ")')
CATEGORICAL_VARIABLES=$(get_json_value '.categorical_variables | join(" ")')

ELEMENT_SUBSET_R=""
ELEMENT_RANGE_START=""
ELEMENT_RANGE_END=""

if [[ "$ELEMENT_SUBSET_JSON" != "null" && "$ELEMENT_RANGE_JSON" != "null" ]]; then
  echo "🛑 Use either element_subset or element_range, not both."
  exit 1
fi

if [[ "$ELEMENT_SUBSET_JSON" != "null" ]]; then
  if ! jq -e '(.element_subset | type) == "array" and (.element_subset | length) > 0 and (.element_subset | all(.[]; type == "number" and floor == . and . >= 1))' "$CONFIG_PATH" >/dev/null; then
    echo "🛑 element_subset must be a non-empty array of 1-based integers."
    exit 1
  fi
  ELEMENT_SUBSET_R=$(get_json_value '.element_subset | map(tostring) | join(", ")')
fi

if [[ "$ELEMENT_RANGE_JSON" != "null" ]]; then
  if ! jq -e '(.element_range | type) == "array" and (.element_range | length) == 2 and (.element_range | all(.[]; type == "number" and floor == . and . >= 1)) and (.element_range[0] <= .element_range[1])' "$CONFIG_PATH" >/dev/null; then
    echo "🛑 element_range must be [start, end] with 1-based integers and start <= end."
    exit 1
  fi
  ELEMENT_RANGE_START=$(get_json_value '.element_range[0]')
  ELEMENT_RANGE_END=$(get_json_value '.element_range[1]')
fi

MODEL_OPTIONS_R=$(printf '%s\n' "$MODEL_OPTIONS_JSON" | jq -r '
  def to_r:
    if type == "string" then @json
    elif type == "number" then tostring
    elif type == "boolean" then (if . then "TRUE" else "FALSE" end)
    elif type == "null" then "NULL"
    elif type == "array" then
      if length == 0 then "c()"
      else "c(" + (map(to_r) | join(", ")) + ")"
      end
    elif type == "object" then
      "list(" + (to_entries | map(.key + " = " + (.value | to_r)) | join(", ")) + ")"
    else
      error("Unsupported JSON type for model_options")
    end;
  to_r
')


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
load_modelarray <- function(h5_path, scalar_name, analysis_name) {
  # Reruns often have only a custom analysis name in H5 (not myAnalysis).
  obj <- try(ModelArray(h5_path, scalar_types = c(scalar_name), analysis_names = c(analysis_name)), silent = TRUE)
  if (!inherits(obj, "try-error")) {
    return(obj)
  }

  # First-run files may have no analysis group yet, so fall back to defaults.
  obj_default <- try(ModelArray(h5_path, scalar_types = c(scalar_name)), silent = TRUE)
  if (!inherits(obj_default, "try-error")) {
    return(obj_default)
  }

  stop(paste0(
    "Unable to load ModelArray data with analysis '", analysis_name, "' and default analysis settings.\n",
    "First error: ", as.character(obj), "\n",
    "Second error: ", as.character(obj_default)
  ))
}

modelarray <- load_modelarray(h5_path, "$SCALER_TYPE", "$ANALYSIS_NAME")
phenotypes <- read.csv(csv_path)
element_subset <- NULL

# Demean and center continuous covariates
EOF

if [ -n "$ELEMENT_SUBSET_R" ]; then
cat >> "$R_SCRIPT_PATH" <<EOF
element_subset <- as.integer(c($ELEMENT_SUBSET_R))

EOF
fi

if [[ -n "$ELEMENT_RANGE_START" && -n "$ELEMENT_RANGE_END" ]]; then
cat >> "$R_SCRIPT_PATH" <<EOF
element_subset <- seq.int($ELEMENT_RANGE_START, $ELEMENT_RANGE_END)

EOF
fi

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
model_options <- $MODEL_OPTIONS_R

# ── Progress helpers ──────────────────────────────────────────────────────────
ts <- function(msg) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), msg))
  flush.console()
}

n_elements_total <- numElementsTotal(modelarray, "$SCALER_TYPE")
n_elements <- if (is.null(element_subset)) n_elements_total else length(element_subset)
ts(sprintf("Starting ${MODEL_TYPE} on %s: %d/%d elements, %d cores", "$SCALER_TYPE", n_elements, n_elements_total, $N_CORES))

heartbeat_enabled <- TRUE

# Force pbmclapply progress output in non-interactive logs when running in parallel.
if ($N_CORES > 1) {
  if (!"ignore.interactive" %in% names(model_options)) {
    model_options\$ignore.interactive <- TRUE
  }
  ts("Parallel progress bar enabled (percentage + ETA).")
}

t_start <- proc.time()

# Heartbeat for long single-core runs. For parallel runs, percentage progress is cleaner.
heartbeat <- NULL
if (heartbeat_enabled) {
  heartbeat <- parallel::mcparallel({
    repeat { Sys.sleep(30); cat(sprintf("[%s] Still fitting...\n", format(Sys.time(), "%H:%M:%S"))); flush.console() }
  })
}

model_args <- c(
  list(
    formula = formula,
    data = modelarray,
    phenotypes = phenotypes,
    scalar = "$SCALER_TYPE",
    element.subset = element_subset,
    num.subj.lthr.abs = $NUM_ABS,
    num.subj.lthr.rel = $NUM_REL,
    full.outputs = $FULL_OUTPUTS,
    n_cores = $N_CORES,
    verbose = TRUE,
    pbar = TRUE
  ),
  model_options
)

mylm <- do.call(ModelArray.${MODEL_TYPE}, model_args)

if (!is.null(heartbeat)) {
  tools::pskill(heartbeat\$pid, signal = 15L)
}

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
echo "📊 Live fit stats: progress % + throughput + ETA + finish time"

# Run the model analysis with inline progress summaries parsed from the
# percentage progress stream.
MODEL_START_EPOCH=$(date +%s)
AWK_BIN=$(command -v gawk || command -v awk)
THREAD_ENV_ARGS=(
  --env OMP_NUM_THREADS=1
  --env OPENBLAS_NUM_THREADS=1
  --env MKL_NUM_THREADS=1
  --env BLIS_NUM_THREADS=1
  --env VECLIB_MAXIMUM_THREADS=1
  --env NUMEXPR_NUM_THREADS=1
)
set +e
singularity run --cleanenv -B "$DATA_DIR:/data" \
  "${THREAD_ENV_ARGS[@]}" \
  "$CONTAINER" Rscript /data/$(basename "$R_SCRIPT_PATH") 2>&1 \
  | "$AWK_BIN" -v RS='[\r\n]+' -v ORS='\n' -v start_epoch="$MODEL_START_EPOCH" '
      function fmt_hms(sec, h, m, s) {
        if (sec < 0) sec = 0
        h = int(sec / 3600)
        m = int((sec % 3600) / 60)
        s = int(sec % 60)
        return sprintf("%02d:%02d:%02d", h, m, s)
      }
      {
        line = $0
        if (line == "") next
        if (match(line, /Starting [A-Za-z0-9_]+ on .*: ([0-9]+)\/[0-9]+ elements/, m)) {
          print line
          total_elements = m[1] + 0
          next
        }

        if (match(line, /([0-9]{1,3})%, ETA[[:space:]]*[0-9:]+/, p)) {
          pct = p[1] + 0

          # Suppress repeated 1%, 2%, ... progress-bar redraw lines.
          if (pct != last_bar_pct) {
            print line
            fflush()
            last_bar_pct = pct
          }

          if (pct > 0 && pct != last_pct) {
            now = systime()
            elapsed = now - start_epoch
            eta = int(elapsed * (100 - pct) / pct)
            finish = now + eta

            if (total_elements > 0) {
              elems_done = total_elements * pct / 100.0
              rate = elems_done / (elapsed > 0 ? elapsed : 1)
              printf("[%s] Progress %d%% | %.2f elem/s | ETA %s | Finish ~%s\n", strftime("%H:%M:%S", now), pct, rate, fmt_hms(eta), strftime("%H:%M:%S", finish))
            } else {
              printf("[%s] Progress %d%% | ETA %s | Finish ~%s\n", strftime("%H:%M:%S", now), pct, fmt_hms(eta), strftime("%H:%M:%S", finish))
            }

            fflush()
            last_pct = pct
          }

          next
        }

        print line
      }
    ' \
  | tee "$LOG_FILE"
MODEL_EXIT=${PIPESTATUS[0]}
set -e

if [ "$MODEL_EXIT" -ne 0 ]; then
  echo "🛑 Model analysis failed. See log: $LOG_FILE"
  exit 1
fi

# Write results to NIfTI
echo "📦 Writing output NIfTI files..."
singularity run --cleanenv -B "$DATA_DIR:/data" \
  "${THREAD_ENV_ARGS[@]}" \
  "$CONTAINER" volumestats_write \
  --group-mask-file "/data/$GROUP_MASK" \
  --cohort-file "/data/$CSV_FILE" \
  --relative-root /data \
  --analysis-name "$ANALYSIS_NAME" \
  --input-hdf5 "/data/$H5_FILE" \
  --output-dir "/data/$OUTPUT_DIR" \
  --output-ext "$OUTPUT_EXT" 2>&1 | tee -a "$LOG_FILE"

echo "✅ All steps completed successfully. Full log: $LOG_FILE"
