#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inspect_modelarray_h5.sh H5_FILE [SCALAR_NAME] [ANALYSIS_NAME] [COHORT_CSV] [CONTAINER]

Quickly inspect a ModelArray HDF5 using the convenience functions highlighted in
the upstream exploring-h5 vignette.

Arguments:
  H5_FILE       Path to the ModelArray HDF5 file.
  SCALAR_NAME   Optional scalar to load explicitly.
  ANALYSIS_NAME Optional saved analysis to load explicitly.
  COHORT_CSV    Optional phenotype CSV for exampleElementData().
  CONTAINER     Optional Singularity image to use when host R lacks ModelArray.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage

H5_FILE="$1"
SCALAR_NAME="${2:-}"
ANALYSIS_NAME="${3:-}"
COHORT_CSV="${4:-}"
CONTAINER="${5:-/data/local/container/modelarray/modelarray_confixel_0.1.5.sif}"

[[ -f "$H5_FILE" ]] || { echo "ERROR: H5 file not found: $H5_FILE" >&2; exit 1; }
if [[ -n "$COHORT_CSV" ]]; then
  [[ -f "$COHORT_CSV" ]] || { echo "ERROR: Cohort CSV not found: $COHORT_CSV" >&2; exit 1; }
fi

run_rscript() {
  if command -v Rscript >/dev/null 2>&1 && Rscript --vanilla -e 'library(ModelArray)' >/dev/null 2>&1; then
    Rscript --vanilla - "$H5_FILE" "$SCALAR_NAME" "$ANALYSIS_NAME" "$COHORT_CSV"
    return
  fi

  command -v singularity >/dev/null 2>&1 || { echo "ERROR: Neither host R+ModelArray nor singularity is available." >&2; exit 1; }
  [[ -f "$CONTAINER" ]] || { echo "ERROR: Container not found: $CONTAINER" >&2; exit 1; }

  bind_args=( -B "$(dirname "$H5_FILE")":"$(dirname "$H5_FILE")" )
  if [[ -n "$COHORT_CSV" ]]; then
    bind_args+=( -B "$(dirname "$COHORT_CSV")":"$(dirname "$COHORT_CSV")" )
  fi

  singularity run --cleanenv "${bind_args[@]}" "$CONTAINER" Rscript - "$H5_FILE" "$SCALAR_NAME" "$ANALYSIS_NAME" "$COHORT_CSV"
}

run_rscript <<'RSCRIPT'
args <- commandArgs(trailingOnly = TRUE)
h5_path <- args[[1]]
scalar_name <- args[[2]]
analysis_name <- args[[3]]
cohort_csv <- args[[4]]

library(ModelArray)

if (exists("h5summary", where = asNamespace("ModelArray"), mode = "function")) {
  summary_obj <- h5summary(h5_path)
  print(summary_obj)
} else {
  cat("h5summary() not available in this ModelArray version; using show() after load instead.\n")
}

scalar_types <- if (nzchar(scalar_name)) scalar_name else NULL
analysis_names <- if (nzchar(analysis_name)) analysis_name else NULL

modelarray <- ModelArray(h5_path, scalar_types = scalar_types, analysis_names = analysis_names)
show(modelarray)

get_scalar_names <- function(x) {
  if (exists("scalarNames", where = asNamespace("ModelArray"), mode = "function")) {
    scalarNames(x)
  } else {
    names(scalars(x))
  }
}

get_analysis_names <- function(x) {
  if (exists("analysisNames", where = asNamespace("ModelArray"), mode = "function")) {
    analysisNames(x)
  } else {
    names(results(x))
  }
}

count_elements <- function(x, scalar) {
  if (exists("nElements", where = asNamespace("ModelArray"), mode = "function")) {
    nElements(x, scalar)
  } else {
    numElementsTotal(x, scalar)
  }
}

count_inputs <- function(x, scalar) {
  if (exists("nInputFiles", where = asNamespace("ModelArray"), mode = "function")) {
    nInputFiles(x, scalar)
  } else {
    ncol(scalars(x)[[scalar]])
  }
}

scalar_names <- get_scalar_names(modelarray)
analysis_names_loaded <- get_analysis_names(modelarray)

cat("\nScalar names:\n")
print(scalar_names)

cat("\nAnalysis names:\n")
print(analysis_names_loaded)

if (length(scalar_names) > 0) {
  scalar <- scalar_names[[1]]
  cat("\nSource files for", scalar, ":\n")
  print(head(sources(modelarray)[[scalar]]))
  cat("\nDimensions for", scalar, ":\n")
  print(dim(scalars(modelarray)[[scalar]]))
  cat("\nNumber of elements:", count_elements(modelarray, scalar), "\n")
  cat("Number of inputs:", count_inputs(modelarray, scalar), "\n")
}

if (length(analysis_names_loaded) > 0) {
  analysis <- analysis_names_loaded[[1]]
  cat("\nResult columns for", analysis, ":\n")
  print(colnames(results(modelarray)[[analysis]]))
}

if (nzchar(cohort_csv) && length(scalar_names) > 0) {
  phenotypes <- read.csv(cohort_csv)
  scalar <- scalar_names[[1]]
  cat("\nexampleElementData() preview for element 1:\n")
  print(head(exampleElementData(modelarray, scalar = scalar, i_element = 1, phenotypes = phenotypes)))
}
RSCRIPT