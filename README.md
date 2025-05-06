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

This toolkit provides a 3-step command-line pipeline:

1. **Cohort creation**
2. **ModelArray analysis**
3. **Flexible execution via JSON config**

Each step is fully scripted and validated for reproducibility and consistency.

---

## 🔄 Pipeline Summary

```text
participants.tsv + image/mask data
         │
         ▼
generate_cohort.sh
         │
         ▼
   cohort_*.csv
         │
         ▼
run_convoxel.sh OR model_run.sh
         │
         ▼
  HDF5 + CSV + NIfTI stats
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

### 2. [`run_convoxel.sh`](./run_convoxel.sh)

Validates a cohort and group mask, then runs ModelArray via a Singularity container.

**Usage:**

```
./run_modelarray.sh -c cohort_ISOVF.csv -r /data/study
```

➡️ See the [README for `run_modelarray.sh`](#run_modelarraysh) for validation and output details.

------

### 3. [`run_model.sh`](./run_model.sh)

Takes a single JSON config file and performs the entire analysis, including volumetric output.

**Usage:**

```
./run_from_json.sh path/to/config.json
```

➡️ See the [README for `run_model.sh`](#run_modelsh) for JSON structure and automation details.

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
