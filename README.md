# 🧠 ModelArray Processing Pipeline

Automated voxelwise statistical analysis using [ModelArray](https://github.com/pnlbwh/ModelArray), optimized for neuroimaging studies. Runs inside a Singularity container.

---

## 🚀 Quick Start

```bash
# Run a complete modality analysis (e.g., all NODDI or MAPMRI scalars)
./run_analysis.sh configs/pipeline_noddi_gam_2mm.json

# Run in background with nohup
./run_analysis.sh --nohup configs/pipeline_mapmri_wholebrain_2group_gam_2mm.json

# Dry-run to preview commands without executing
./run_analysis.sh --dry-run configs/pipeline_noddi_gam_2mm.json

# Run only one scalar from a modality config
./run_analysis.sh --scalar icvf_dwimap configs/pipeline_noddi_gam_2mm.json

# Skip the ML step (statistics only)
./run_analysis.sh --skip-ml configs/pipeline_noddi_gam_2mm.json

# Skip registration (data already in MNI space)
./run_analysis.sh --skip-reg configs/pipeline_noddi_gam_2mm.json

# Force regeneration of all intermediate files
./run_analysis.sh --force configs/pipeline_noddi_gam_2mm.json

# Combine options
./run_analysis.sh --nohup --skip-ml --scalar od_dwimap configs/pipeline_noddi_gam_2mm.json
```

### Real-World Example Output

```
$ ./run_analysis.sh --dry-run configs/pipeline_noddi_gam_2mm.json

INFO: Detected modality-level config: noddi (3 scalars)
[15:00:00] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[15:00:00] ModelArray Analysis Pipeline
[15:00:00] Config: pipeline_noddi_gam_2mm
[15:00:00] Type: modality
[15:00:00] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[15:00:02] Using scalars: icvf_dwimap od_dwimap isovf_dwimap
[15:00:02] Scalar 1/3: icvf_dwimap
[15:00:02] Generated config: .../configs/generated/icvf_dwimap.json
[15:00:02] bash .../ModelArray/_run_scalar_pipeline.sh --dry-run ...
[15:00:02] Scalar 1/3 complete: icvf_dwimap in 00:00:00 | overall 33% in 00:00:00
...
[15:00:03] All scalar pipelines completed.
```

---

## 📚 Table of Contents

1. [Quick Start](#-quick-start)
2. [Pipeline Overview](#-pipeline-overview)
3. [Config Types](#-config-types)
4. [run_analysis.sh Options](#-run_analysissh-options)
5. [Individual Scripts](#-individual-scripts)
6. [Requirements](#-requirements)

---

## 🔄 Pipeline Overview

```text
run_analysis.sh (unified entry point)
         │
         ├── Modality config? ──► _run_modality_batch.sh (loops scalars)
         │                                │
         │                                ▼ (per scalar)
         └── Scalar config? ────► _run_scalar_pipeline.sh
                                          │
         ┌────────────────────────────────┘
         │
         ▼
    A. 0_register_acpc_to_mni.sh  (optional)
         │
         ▼
    B. Group mask preparation
         │
         ▼
    C. 1_generate_cohort*.sh
         │
         ▼
    D. 2_run_convoxel.sh  →  cohort_*.h5
         │
         ▼
    E. 3_run_model.sh  →  NIfTI stats + CSV summaries
         │
         ▼
    F. 4_run_ml.py  →  ML metrics + predictions (optional)
```

---

## 📋 Config Types

### Modality Config (batch mode)
Processes **multiple scalars** for a modality (NODDI, MAPMRI, etc.):

```json
{
  "dataset": { "bids_dir": "...", "output_dir": "..." },
  "modality": { "name": "noddi", "scalars": ["icvf_dwimap", "od_dwimap"] },
  "statistics": { "model_type": "gam", "formula_template": "..." }
}
```

### Scalar Config (single mode)
Processes **one scalar** through the full pipeline:

```json
{
  "data_dir": "...",
  "csv_file": "cohort_icvf_dwimap.csv",
  "h5_file": "cohort_icvf_dwimap.h5",
  "formula": "icvf_dwimap ~ s(delta_age) + group + sex"
}
```

---

## ⚙️ run_analysis.sh Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Print commands without executing |
| `--nohup` | Run detached in background (logs to output_dir or /tmp) |
| `--scalar NAME` | Run only this scalar (modality configs only) |
| `--skip-reg` | Skip registration step |
| `--skip-ml` | Skip machine learning step |
| `--force` | Regenerate all intermediate files |
| `-h, --help` | Show help message |

---

## 📜 Individual Scripts

### `1_generate_cohort.sh` / `1_generate_cohort_longitudinal.sh`

Creates a cohort CSV from participant list, images, and masks.

```bash
./1_generate_cohort_longitudinal.sh -p participants.tsv -d scalar_dir -m mask_dir -o output_dir
```

### `2_run_convoxel.sh`

Extracts voxel data into HDF5 format.

```bash
./2_run_convoxel.sh -c cohort_icvf.csv -g group_mask.nii.gz
```

### `3_run_model.sh`

Runs GAM/LM model fitting from a JSON config.

```bash
./3_run_model.sh config.json
```

The config maps directly to the underlying ModelArray call. `num_subj_lthr_abs`
and `num_subj_lthr_rel` correspond to the voxelwise subject-threshold behavior
documented in the ModelArray reference. An optional `element_subset` JSON array
is also supported for smoke tests or chunked runs.

### `4_run_ml.py`

Runs an optional pattern-recognition stage directly on the existing ModelArray
HDF5 matrix (`scalars/<scalar>/values`) plus cohort labels from CSV.

Supported tasks:
- `classification`
- `regression`

Supported models:
- `random_forest`
- `svm_rbf`
- `elastic_net`
- `xgboost` (optional dependency)

This stage is automatically invoked by `run_analysis.sh` when
`ml.enabled` is `true` (unless `--skip-ml` is passed).

Example scalar-level JSON block:

```json
"ml": {
   "enabled": true,
   "task": "classification",
   "target_column": "group",
   "group_column": "participant",
   "id_columns": ["participant", "session"],
   "n_splits": 5,
   "random_seed": 42,
   "models": ["random_forest", "svm_rbf", "elastic_net"],
   "output_dir": "results/icvf_gam_2mm/ml"
}
```

For modality configs, place the same block under `statistics.ml`.

------

## ⚙️ Requirements

- **Bash**
- `jq` (for JSON parsing)
- [`mrinfo`](https://mrtrix.readthedocs.io/) (from MRtrix3)
- `singularity`
- A valid `modelarray_confixel_0.1.5.sif` container file

------

## 📝 Repo Notes

### Execution Strategy (Current)

- Keep core ModelArray steps containerized for reproducibility:
   - `2_run_convoxel.sh`
   - `3_run_model.sh`
   - `volumestats_write` export
- Keep orchestration and lightweight prep on host:
   - JSON orchestration wrappers
   - cohort table generation
   - registration/linking helpers

### Pattern-Recognition / ML Plan

- Use the existing ModelArray HDF5 (`.h5`) outputs as ML input features.
- First prototype ML stage locally on host for rapid iteration.
- If local prototype is stable and useful, build a project-specific container for the ML stage.
- Goal state: default ML execution in container, with optional local mode for debugging.

### Why This Policy

- Fast iteration during method development.
- Reproducible production runs once methods are finalized.
- Clear separation between experimental and production workflows.

------

## 📂 Folder Structure

Expected organization of data:

```
project/
├── participants.tsv
├── group_mask.nii.gz
├── cohort_FA.csv
├── FA.h5
├── voxelwise_FA_stats_summary.csv
├── subject1/
│   ├── subject1_FA.nii.gz
│   └── subject1_mask.nii.gz
└── ...
```

------

## 📄 License

MIT License

------

## 👥 Authors

- Karl Koschutnig MRI-Lab Graz
- Contributions welcome!
