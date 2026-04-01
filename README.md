# 🧠 ModelArray Processing Pipeline

This repository contains a set of Bash scripts to automate a full voxelwise statistical analysis workflow using [ModelArray](https://github.com/pnlbwh/ModelArray). The pipeline is optimized for neuroimaging studies and runs inside a Singularity container.

---

## 📚 Table of Contents

1. [Overview](#-overview)
2. [Pipeline Summary](#-pipeline-summary)
3. [Usage](#-usage)
4. [Scripts](#-scripts)
   - [`generate_cohort.sh`](#1-generate_cohortsh)
   - [`run_convoxel.sh`](#2-run_convoxelsh)
   - [`model_run.sh`](#3-Model_runsh)
5. [Requirements](#-requirements)
6. [Folder Structure](#-folder-structure)
7. [License](#-license)

---

## 🧭 Overview

This toolkit provides a command-line pipeline for:

1. **Optional ACPC to MNI registration/linking**
2. **Cohort creation**
3. **HDF5 creation with convoxel**
4. **ModelArray analysis**
5. **Flexible execution via JSON config**

Each step is fully scripted and validated for reproducibility and consistency.

---

## 🔄 Pipeline Summary

```text
optional registration/linking
         │
         ▼
participants.tsv + image/mask data + group mask
         │
         ▼
1_generate_cohort*.sh
         │
         ▼
   cohort_*.csv
         │
         ▼
2_run_convoxel.sh
         │
         ▼
      cohort_*.h5
         │
         ▼
3_run_model.sh
         │
         ▼
  CSV summaries + HDF5 results + NIfTI stats
```



## 🚀 Usage

Each script can be run independently, or as part of a batch process. See below for individual usage instructions.

------

## 📜 Scripts

### 1. [`generate_cohort.sh`](./generate_cohort.sh)

Creates a cohort CSV file from a participant list, image files, and subject-specific masks.

**Usage:**

```
./generate_cohort.sh -p participants.tsv -d NII_folder -m mask_folder [-o output_folder]
```

➡️ See the [README for `generate_cohort.sh`](#generate_cohortsh) for full details.

### 2. [`2_run_convoxel.sh`](./2_run_convoxel.sh)

Validates a cohort and group mask, then runs ModelArray via a Singularity container.

**Usage:**

```
./2_run_convoxel.sh -c cohort_ISOVF.csv -g /path/to/group_mask.nii.gz
```

➡️ See the [README for `run_modelarray.sh`](#run_modelarraysh) for validation and output details.

------

### 3. [`3_run_model.sh`](./3_run_model.sh)

Takes a single JSON config file and performs the model stage, including volumetric output.

**Usage:**

```
./3_run_model.sh path/to/config.json
```

The config maps directly to the underlying ModelArray call. `num_subj_lthr_abs`
and `num_subj_lthr_rel` correspond to the voxelwise subject-threshold behavior
documented in the ModelArray reference. An optional `element_subset` JSON array
is also supported for smoke tests or chunked runs.

### 4. [`run_full_from_json.sh`](./run_full_from_json.sh)

Runs the full pipeline from one JSON config by orchestrating the existing stage
scripts. This is the entrypoint to use when the cohort CSV and HDF5 do not exist
yet.

When registration is enabled, the wrapper also routes subject brain masks through
[0_register_acpc_to_mni.sh](0_register_acpc_to_mni.sh) into standard space by
default, using the cohort mask directory unless `registration.mask_dir` is set
explicitly.

**Usage:**

```
./run_full_from_json.sh path/to/config.json
./run_full_from_json.sh --dry-run path/to/config.json
```

For a full run, add optional `registration`, `cohort`, `convoxel`, and
`group_mask_source` fields to the same JSON used by `3_run_model.sh`.

------

## ⚙️ Requirements

- **Bash**
- `jq` (for JSON parsing)
- [`mrinfo`](https://mrtrix.readthedocs.io/) (from MRtrix3)
- `singularity`
- A valid `modelarray_confixel_0.1.5.sif` container file

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
