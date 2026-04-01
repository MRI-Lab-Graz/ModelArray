#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare_longitudinal_participants.sh -p PARTICIPANTS_TSV -q QSIRECON_DIR -o OUTPUT_TSV

Builds a session-level phenotype table from a subject-level participants.tsv and
the subject/session folders present under a qsirecon derivatives tree.

Inputs:
  -p  Subject-level participants TSV. Must contain a participant_id column.
      Session-specific age columns like age@ses-1, age@ses-2, ... are used
      when available to derive delta_age and age_ses1.
  -q  QSIRecon modality derivatives directory, e.g.
      /path/to/derivatives/qsirecon/derivatives/qsirecon-NODDI
  -o  Output TSV path for the derived longitudinal phenotype table.
EOF
  exit 1
}

PARTICIPANTS_TSV=""
QSIRECON_DIR=""
OUTPUT_TSV=""

while getopts ":p:q:o:h" opt; do
  case "$opt" in
    p) PARTICIPANTS_TSV="$OPTARG" ;;
    q) QSIRECON_DIR="$OPTARG" ;;
    o) OUTPUT_TSV="$OPTARG" ;;
    h) usage ;;
    \?) echo "ERROR: Invalid option -$OPTARG" >&2; usage ;;
    :) echo "ERROR: Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

[[ -n "$PARTICIPANTS_TSV" && -n "$QSIRECON_DIR" && -n "$OUTPUT_TSV" ]] || usage
[[ -f "$PARTICIPANTS_TSV" ]] || { echo "ERROR: Participants TSV not found: $PARTICIPANTS_TSV" >&2; exit 1; }
[[ -d "$QSIRECON_DIR" ]] || { echo "ERROR: QSIRecon directory not found: $QSIRECON_DIR" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT_TSV")"

python3 - "$PARTICIPANTS_TSV" "$QSIRECON_DIR" "$OUTPUT_TSV" <<'PY'
import csv
import os
import re
import sys
from collections import defaultdict


participants_tsv, qsirecon_dir, output_tsv = sys.argv[1:4]


def parse_float(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text or text.lower() in {"n/a", "na", "nan", "none"}:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def format_number(value):
    if value is None:
        return ""
    text = f"{value:.12f}".rstrip("0").rstrip(".")
    return text if text else "0"


session_pattern = re.compile(r"^ses-(\d+)$")
age_pattern = re.compile(r"^age@(?P<session>ses-\d+)$")


sessions_by_participant = defaultdict(set)
for entry in sorted(os.listdir(qsirecon_dir)):
    if not entry.startswith("sub-"):
        continue
    sub_dir = os.path.join(qsirecon_dir, entry)
    if not os.path.isdir(sub_dir):
        continue
    found_session = False
    for child in sorted(os.listdir(sub_dir)):
        child_dir = os.path.join(sub_dir, child)
        if os.path.isdir(child_dir) and session_pattern.match(child):
            sessions_by_participant[entry].add(child)
            found_session = True
    if not found_session:
        sessions_by_participant[entry].add("ses-1")

if not sessions_by_participant:
    raise SystemExit(f"ERROR: No subject/session folders found under {qsirecon_dir}")


with open(participants_tsv, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f, delimiter="\t")
    fieldnames = reader.fieldnames or []
    if "participant_id" not in fieldnames:
        raise SystemExit("ERROR: participants.tsv must contain a participant_id column")

    age_columns = {}
    passthrough_columns = []
    for field in fieldnames:
        match = age_pattern.match(field)
        if match:
            age_columns[match.group("session")] = field
            continue
        if field in {"participant_id", "participant", "session", "delta_age", "age_ses1", "age"}:
            continue
        passthrough_columns.append(field)

    output_fields = ["participant_id", "participant", "session", "delta_age", "age_ses1", "age"] + passthrough_columns

    rows_out = []
    for row in reader:
        participant = (row.get("participant_id") or "").strip()
        if not participant:
            continue
        sessions = sorted(
            sessions_by_participant.get(participant, []),
            key=lambda item: int(session_pattern.match(item).group(1)) if session_pattern.match(item) else item,
        )
        if not sessions:
            continue

        baseline_age = parse_float(row.get(age_columns.get("ses-1", ""), ""))
        for session in sessions:
            age_value = parse_float(row.get(age_columns.get(session, ""), ""))
            delta_age = None
            if baseline_age is not None and age_value is not None:
                delta_age = age_value - baseline_age

            out_row = {
                "participant_id": f"{participant}_{session}",
                "participant": participant,
                "session": session,
                "delta_age": format_number(delta_age),
                "age_ses1": format_number(baseline_age),
                "age": format_number(age_value),
            }
            for field in passthrough_columns:
                out_row[field] = row.get(field, "")
            rows_out.append(out_row)

with open(output_tsv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=output_fields, delimiter="\t")
    writer.writeheader()
    writer.writerows(rows_out)

print(f"Wrote {len(rows_out)} longitudinal rows to {output_tsv}")
PY