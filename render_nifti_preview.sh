#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: render_nifti_preview.sh INPUT_NIFTI OUTPUT_PNG

Render a quick slice mosaic PNG from a NIfTI file using FSL slicer.
This is intended for fast QA of ModelArray voxelwise outputs.
EOF
  exit 1
}

[[ $# -eq 2 ]] || usage

INPUT_NIFTI="$1"
OUTPUT_PNG="$2"

[[ -f "$INPUT_NIFTI" ]] || { echo "ERROR: Input NIfTI not found: $INPUT_NIFTI" >&2; exit 1; }
command -v slicer >/dev/null 2>&1 || { echo "ERROR: FSL slicer not found in PATH." >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT_PNG")"

slicer "$INPUT_NIFTI" -S 2 1600 "$OUTPUT_PNG"

echo "Wrote preview: $OUTPUT_PNG"