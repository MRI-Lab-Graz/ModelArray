# ModelArray — Hostile Code Assessment & Remediation Roadmap

Adversarial review of `/data/local/software/ModelArray` (entry points, batch/scalar
runners, stage scripts, ML stage, GUI). Issues are written from the perspective
of a skeptical reviewer trying to break, misuse, or distrust the pipeline. Each
item lists severity, location, the failure mode, and a concrete fix.

Severity legend: **P0** = data integrity / silent corruption / security,
**P1** = breaks in realistic use or produces misleading output,
**P2** = correctness/usability nit, **P3** = polish.

---

## 1. Security & Multi-User Safety

### 1.1 [P0] GUI binds to `0.0.0.0` with zero auth, exposes filesystem and arbitrary script execution
[gui/app.py](gui/app.py#L455) calls `serve(app, host="0.0.0.0", ...)`. Anyone on
the network can:
- Browse the filesystem via [`/browse`](gui/app.py#L78) (no path restriction, walks anywhere readable by the host user).
- Read arbitrary phenotype files via [`/parse_tsv`](gui/app.py#L187) (path traversal blocked only by a substring check for `..`; absolute paths like `/etc/passwd` pass straight through).
- Launch arbitrary pipeline runs via [`/run`](gui/app.py#L266); arguments such as `input_dir`, `participants`, `cohort_file` are inserted into a `subprocess.Popen` argv list without any allow-listing — they can point at any path the server user can read/write.
- Kill any job via [`/stop`](gui/app.py#L406) and shut the server down via [`/shutdown`](gui/app.py#L424) with no token check.

**Fix:** bind to `127.0.0.1` by default; require a launch flag (or env var) to expose externally; add a shared-secret token middleware; restrict `/browse` and `/parse_tsv` to a configurable root (e.g. `BIDS_DIR`); reject absolute paths outside that root via `Path.resolve().is_relative_to(root)`.

### 1.2 [P1] Path-traversal checks are substring-based, not canonical
[gui/app.py](gui/app.py#L141) (`save_project`), [`load_project`](gui/app.py#L156), [`get_config`](gui/app.py#L177), [`save_config`](gui/app.py#L209) all guard with `if ".." in name`. This misses absolute paths (`/etc/...`), symlinks, and CRLF-encoded traversal. With write endpoints (`save_project`, `save_config`) this is exploitable to overwrite files anywhere the server user can write.

**Fix:** validate names against a strict regex (`^[A-Za-z0-9_-]+(\.json)?$`) and build paths with `Path(root) / name`, then check `resolved.is_relative_to(root)`.

### 1.3 [P2] `/shutdown` lets any reachable client kill the GUI
With network exposure (1.1) any client can `POST /shutdown` and terminate a running pipeline (the monitor thread loses its handle). Combine with 1.1 → trivial denial of service.

### 1.4 [P2] Hardcoded absolute paths to `/data/local/134_AF19`, `/data/local/templateflow`, `/data/local/container/...`
Defaults are scattered across [0_register_acpc_to_mni.sh](0_register_acpc_to_mni.sh#L17), [_run_modality_batch.sh](_run_modality_batch.sh#L179), [_run_modality_batch.sh](_run_modality_batch.sh#L279), [2_run_convoxel.sh](2_run_convoxel.sh#L148), [inspect_modelarray_h5.sh](inspect_modelarray_h5.sh#L28), [setup_and_run_2mm.sh](setup_and_run_2mm.sh#L23), [run_2mm_full.sh](run_2mm_full.sh#L13). Anyone else cloning this repo is blocked, and quietly bumping a container version (`0.1.5.sif` → `0.1.6.sif`) requires editing many files.

**Fix:** centralize in a single `defaults.env` sourced by every script; require the dataset/container fields in the config and abort if unset.

---

## 2. Data Integrity & Statistical Correctness

### 2.1 [P0] `3_run_model.sh` rewrites the formula with brittle `sed` substitution
[3_run_model.sh](3_run_model.sh#L137-L146) replaces continuous covariate names with `<name>_DM` and categorical ones with `<name>_F` using `sed "s/\\b$covariate\\b/${covariate}_DM/g"` on the user-provided `formula`. Failure modes:
- Word boundaries on dot/underscore: a covariate `sex` will match inside `s(sex_id)`. With our actual configs, `participant` is also a categorical name — the substitution rewrites all occurrences, including `participant_idx` if it appears literally in the formula (it does in [configs/pipeline_mapmri_wholebrain_2group_gam_2mm.json](configs/pipeline_mapmri_wholebrain_2group_gam_2mm.json#L23)) — producing `participant_F_idx`, breaking the random effect.
- Order dependence: replacing `group` before `group_F` is fine, but replacing `participant` after listing it as categorical does not match the literal `participant_idx`, while listing it both ways causes subtle aliasing.
- Special chars in covariate names (parentheses, dots) become regex metacharacters.

**Fix:** build the formula in R (where parsing is structural), not shell. Or maintain explicit `<name> -> <renamed>` substitution using an R `terms()`-based walk; never `sed` over `s(...)` expressions.

### 2.2 [P0] Pre-filter for `by=group_F` silently rewrites the on-disk HDF5
[3_run_model.sh](3_run_model.sh#L226) sets `modelarray@scalars[["$SCALER_TYPE"]][dropped_ids, ] <- NaN`. ModelArray opens the H5 read/write by default; this mutation persists to disk, contaminating the cohort H5 used by Stage 4 ML and any rerun. Also the regex test `grepl("by\\s*=\\s*group_F", formula_text)` runs on the *renamed* formula — but the rename uses `sed` (item 2.1) and may already have produced `group_F_F` if `group_F` was misconfigured as categorical.

**Fix:** keep pre-filter results in an in-memory mask and pass it to `ModelArray.gam` via `element.subset`. Never mutate the scalar matrix in place; if a write is required, write a *copy* of the H5 and operate on the copy.

### 2.3 [P1] Subject-CV grouping vs. ML predictions/CSV
[4_run_ml.py](4_run_ml.py#L312) builds the splitter with `group_column` (typically `participant`) to prevent leakage. Good. But the per-fold metrics call `roc_auc_score(y_test, ...)` using all sessions for a participant pooled into one fold's test set — that is correct for grouping but the *per-row* predictions are still emitted to `predictions.csv` with `participant` and `session` columns, encouraging downstream users to compute per-session metrics that double-count subjects. Document this explicitly, or aggregate to one row per participant before computing `accuracy`/`f1`.

### 2.4 [P1] Classification labels are coerced to `str` after NaN filter, but numeric `target` (e.g. `group=1,2`) ends up as `"1.0"` / `"2.0"`
[4_run_ml.py](4_run_ml.py#L444) does `y_series = y_raw.astype(str)`. Pandas turns numeric `1` into `"1.0"`. Downstream `predictions.csv` then writes `"1.0"`/`"2.0"` strings, mis-aligning with any external label list and breaking joins on `group`. For booleans this is worse (`"True"` vs `True`).

**Fix:** cast via `pd.Categorical(y_raw).astype(str)` after explicitly normalizing numeric labels (`y_raw.astype("Int64").astype(str)` when integral).

### 2.5 [P1] Mean-imputation inside the SVM/EN pipeline silently fills NaNs but never reports how many
[4_run_ml.py](4_run_ml.py#L495-L500) adds a `SimpleImputer(strategy="mean")` for `svm_rbf` and `elastic_net`. Random Forest and XGBoost skip the imputer entirely — XGBoost handles NaNs natively, but `RandomForestClassifier` will *raise* on NaN inputs and the run dies mid-CV after producing partial metrics from earlier models.

**Fix:** check `np.isnan(X).any()` once at load, log the count, and either error out or impute for *all* models uniformly. Add a config flag `ml.impute_strategy`.

### 2.6 [P1] `_run_scalar_pipeline.sh` strict path equality breaks on symlinks / multi-mount paths
[_run_scalar_pipeline.sh](_run_scalar_pipeline.sh#L235-L252) compares `EXPECTED_CSV_PATH` vs. `CONFIGURED_CSV_PATH` after `realpath -m`. If `data_dir` is reachable via two different real paths (NFS mount + bind mount, or via a symlink in one and not the other), the equality fails and the runner aborts even though the files would be created correctly.

**Fix:** compare basenames and parent inode rather than the full string, or accept a `--no-strict-paths` override.

### 2.7 [P1] Cohort generators do not validate that participants TSV rows actually correspond to MNI-space scalars at the configured resolution
[1_generate_cohort_longitudinal.sh](1_generate_cohort_longitudinal.sh#L172) emits a `WARNING` and continues when a NIfTI is missing — the resulting cohort has fewer rows than the participants file but no exit code, and the user only sees the warning in the captured log. Worse, [1_generate_cohort.sh](1_generate_cohort.sh#L188) writes `METADATA` from `${LINE[*]:1}` where `IFS=','`, **discarding embedded commas** in any phenotype column (e.g. a free-text site name "Pittsburgh, PA").

**Fix:** abort by default when any row is missing data (allow `--allow-missing` to opt in); quote CSV fields properly (use `python3 -c 'import csv; ...'` or an `awk` CSV-safe writer).

### 2.8 [P1] `1_generate_cohort.sh` picks scalar/mask files via fuzzy `find ... -name "${subject}*.nii.gz"`
[1_generate_cohort.sh](1_generate_cohort.sh#L42) and [`pick_mask_file`](1_generate_cohort.sh#L9). If two subjects share a prefix (`sub-100`, `sub-1001`) the wrong mask/scalar is picked. The "single file in folder → take it" fallback ([1_generate_cohort.sh](1_generate_cohort.sh#L24)) silently misassigns one mask to every subject when the mask folder has exactly one file.

**Fix:** match on `^${subject}(_|\.)` anchored regex; never fall back to "the only file".

### 2.9 [P1] Longitudinal participant builder always derives `delta_age` and `age_ses1`
[prepare_longitudinal_participants.sh](prepare_longitudinal_participants.sh#L96-L141): when a subject is missing `age@ses-1` the script writes empty `age_ses1` and empty `delta_age` but still emits the row. Downstream GAM with `s(delta_age, ...)` will see NA for that subject — `mgcv` will drop the row with a warning that the user never sees. The cohort H5 still contains that subject's voxels, so the *N* used in fitting differs silently from the *N* reported by `1_generate_cohort_longitudinal.sh`.

**Fix:** abort (or emit a hard "QC" CSV) when any row has unresolvable `delta_age`/`age_ses1`.

### 2.10 [P2] Group-mask resampling in `_run_modality_batch.sh` uses `nearest` interpolation always
[_run_modality_batch.sh](_run_modality_batch.sh#L78) `mrtransform ... -interp nearest`. Correct for binary masks, but the function also moves the *output* into `$group_mask` via `mv -f`, overwriting the user-provided source. If the source path was a symlink into TemplateFlow (typical, see [pipeline_noddi_wholebrain_2group_gam_2mm.json](configs/pipeline_noddi_wholebrain_2group_gam_2mm.json#L21)), and the resampling happens, the *copy already made into $OUTPUT_DIR/group_mask.nii.gz* is overwritten — OK. But the dimension check uses `mrinfo -size` which compares spatial extents only, not voxel spacing or orientation; mismatched qform/sform between a `res-02` template and a 2mm-but-different-grid scalar will silently pass.

**Fix:** also compare `mrinfo -vox` and `mrinfo -transform`; abort on mismatch instead of resampling.

---

## 3. Shell Robustness

### 3.1 [P0] `(( var++ )) || true` antipattern is everywhere; counters may zero out under `set -e`
[1_generate_cohort_longitudinal.sh](1_generate_cohort_longitudinal.sh#L175), [0_register_acpc_to_mni.sh](0_register_acpc_to_mni.sh#L265). The `|| true` is a workaround for `((x++))` returning non-zero when `x=0`. Acceptable, but the same pattern is used to count *failures* — a single failed-counter increment can hide a real failure when combined with `set -e -o pipefail` removed locally. Audit and replace with `: $((x+=1))` which is always exit 0.

### 3.2 [P1] `3_run_model.sh` does not `set -e`
[3_run_model.sh](3_run_model.sh#L1-L20) starts with a bare `#!/bin/bash` and no `set -euo pipefail`. The R script generation, the Singularity launch, and the post-run NIfTI export each fail independently. The script does check `$MODEL_EXIT` for the model run, but the `volumestats_write` step's exit status is *not* checked — failures here are reported only via `tee` output, so a missing voxelwise NIfTI export looks like success.

**Fix:** add `set -uo pipefail`; capture `${PIPESTATUS[0]}` after the second `singularity run | tee`.

### 3.3 [P1] Heredoc R script generation interpolates user input directly
[3_run_model.sh](3_run_model.sh#L150-L320) writes the formula, scalar name, analysis name, and `MODEL_OPTIONS_R` into the heredoc without any quoting. A scalar named `foo"); system("rm -rf "` (admittedly contrived, but more realistic: any single quote or backslash in a config value) will produce broken R code that fails at parse time. With the GUI exposed (1.1) this becomes a remote code execution surface inside the container.

**Fix:** pass these as command-line arguments to a checked-in `.R` file (`Rscript model.R --scalar "$SCALER_TYPE" --formula "$FORMULA"`), and use `commandArgs(trailingOnly=TRUE)` inside R; never `cat <<EOF` user data into source code.

### 3.4 [P1] `apply_overrides` in `run_analysis.sh` leaks temp files on `kill -9`
[run_analysis.sh](run_analysis.sh#L180-L225) uses `mktemp --suffix=.json` then `trap cleanup EXIT`. But the runner is `exec`'d into `_run_modality_batch.sh` or `_run_scalar_pipeline.sh` at [run_analysis.sh](run_analysis.sh#L262) — the parent shell is replaced and the EXIT trap never fires. The temp config file leaks into `/tmp` on every overridden run.

**Fix:** unset the trap before `exec`, and write the override to `$OUTPUT_DIR/configs/generated/_override.json` (deterministic, easy to clean up).

### 3.5 [P2] Nohup-launched detached jobs lose their override config when the parent shell exits
Same chain as 3.4: `--nohup` launches `bash "$0"` with the *path to the override temp file* at [run_analysis.sh](run_analysis.sh#L240), then exits. The original `trap cleanup EXIT` deletes the override before the detached child reads it. Race condition; the child may or may not see the file depending on FS timing.

**Fix:** when entering nohup mode, materialize the override config to a non-tmp persistent path before launching.

### 3.6 [P2] `parallel --halt soon,fail=1` in registration silently truncates further work
[0_register_acpc_to_mni.sh](0_register_acpc_to_mni.sh#L355). On first failure, in-flight jobs finish but no more are launched. `PROCESSED=${#JOB_LIST[@]}` is then assigned anyway, so the "Processed: N" line lies.

**Fix:** count actual successful returns via `parallel --joblog`.

### 3.7 [P2] `2_run_convoxel.sh` "common prefix" bind logic
[2_run_convoxel.sh](2_run_convoxel.sh#L128-L143) computes a longest-common-prefix path across realpaths and binds it into the container. If two symlinks resolve to `/data/A/...` and `/mnt/B/...`, the common prefix collapses to `/`, and the script binds the host root into the container. Severely overscoped on shared systems.

**Fix:** compute one bind per *distinct* parent directory of the resolved files, not a common prefix; cap to a configurable allow-list.

### 3.8 [P2] `setup_and_run_2mm.sh` overwrites `group_mask.nii.gz` unconditionally
[setup_and_run_2mm.sh](setup_and_run_2mm.sh#L46-L52) `cp` blasts the templateflow mask in every run, then copies it again to root. Loses any per-cohort group mask the user may have intentionally regenerated.

### 3.9 [P3] `_run_modality_batch.sh` `run_step` echoes commands via `printf '%q '` but with no `tee` to file
Logging relies on stdout being redirected externally. In `--nohup` mode this works; in foreground it dies with the terminal. Add an explicit `LOG_FILE` in non-nohup runs too.

---

## 4. Configuration & UX

### 4.1 [P1] Two config schemas (modality vs. scalar) with overlapping keys but no JSON Schema
[run_analysis.sh](run_analysis.sh#L156-L170) detects "modality" by presence of `dataset+modality+statistics` and "scalar" by `data_dir+csv_file+h5_file`. A user who supplies all five fields gets "modality" silently. Bad configs (missing typed keys, wrong shape for `categorical_variables`, `int` vs `string` for `resolution`) are caught only when downstream scripts fail.

**Fix:** add a `schemas/` directory with JSON Schema for both shapes; validate with `jsonschema` (Python) or `ajv` early in `run_analysis.sh`. Reject ambiguous configs.

### 4.2 [P1] `scaler_type` vs `scalar_type` typo is canonized
The codebase variously reads `.scaler_type` (R: [3_run_model.sh](3_run_model.sh#L39); Python: [4_run_ml.py](4_run_ml.py#L298)) but `_run_modality_batch.sh` emits both correctly. New contributors writing configs with `scalar_type` will silently get an empty value because `jq -r '.scaler_type // empty'` returns `""` and the runner errors with "scaler_type is required".

**Fix:** accept both keys; warn-then-migrate. Pick `scalar_type` as canonical (matches BIDS terminology) and deprecate `scaler_type`.

### 4.3 [P2] `ml.n_jobs` default is `-1` (all cores) regardless of `statistics.n_cores`
[4_run_ml.py](4_run_ml.py#L342). On a shared host with `n_cores: 1` set for the GAM stage out of consideration for other users, the ML stage still spawns one fit per CPU. Random Forest with 500 trees × multi-fold × all cores on a 64-core box will starve everything else.

**Fix:** default `ml.n_jobs` to `min(4, statistics.n_cores)` when unset.

### 4.4 [P2] `MODEL_OPTIONS_R` jq-to-R serializer rejects non-leaf types but is too permissive on strings
[3_run_model.sh](3_run_model.sh#L94-L107): string values are JSON-escaped and passed to R as-is. A value like `"REML"` becomes the R literal `"REML"` — fine. A value like `"y ~ x"` would be passed as a string, but the user might *expect* it to be parsed as a formula. There is no documentation about which `mgcv::gam` options accept strings vs. unquoted symbols.

### 4.5 [P3] CLI flags vs. config keys diverge
`run_analysis.sh` exposes `--skip-reg`, `--skip-ml`, `--force`, `--scalar`. The underlying scripts have their own flags (`-f`, `-d`, `-s` overloaded between resolution and subgroup). Hard to learn.

---

## 5. Reproducibility & Provenance

### 5.1 [P1] No record of which container/version produced an output
Each stage hardcodes a container path (`modelarray_confixel_0.1.5.sif`). The H5 result does carry an `analysis_name`, but neither the cohort CSV, summary CSV, nor ML metrics record the container SHA, repo commit, or config hash.

**Fix:** at start of every run, write `<output_dir>/_provenance.json` with: git commit (`git -C "$SCRIPT_DIR" rev-parse HEAD`), container path + `sha256sum`, full effective config (after overrides), hostname, start time, user.

### 5.2 [P2] Generated R script `generated_script.R` is overwritten every run
[3_run_model.sh](3_run_model.sh#L150). Last run wins; impossible to compare runs after the fact.

**Fix:** name it `generated_script_${ANALYSIS_NAME}_${TIMESTAMP}.R` and keep alongside the log.

### 5.3 [P2] `4_run_ml.py` writes results unconditionally even when CV folds are degenerate
[4_run_ml.py](4_run_ml.py#L460) — if `min_class_n < n_splits`, the code silently reduces `n_splits` rather than warning + recording the effective fold count in the summary header.

**Fix:** record `requested_n_splits` and `effective_n_splits` in `summary.json`.

### 5.4 [P3] No `requirements.txt` lockfile and the file double-lists Flask/Waitress
[requirements.txt](requirements.txt) lists `flask`, `jinja2`, `waitress` twice. Use `pip-compile`/`uv` and commit a `requirements.lock`.

---

## 6. Test & QA Gaps

### 6.1 [P0] No automated tests of any kind
Zero `test_*.py`/`*_test.sh` files; no CI; no `--dry-run` parity test. The whole pipeline is verified by manual eyeballing of `nohup_*.log` (e.g. the user's currently-open log).

**Fix:** add `tests/`:
1. Schema tests for each config in `configs/`.
2. A tiny synthetic dataset (8 subjects × 2 sessions × 5×5×5 voxels) committed under `tests/fixtures/`; a top-level `make test` that runs full pipeline + ML on it.
3. Property tests for `prepare_longitudinal_participants.sh` (missing age sessions, single-session subjects, etc.).
4. Regression test: after rerunning a fixed config, `metrics.csv` and `summary.json` are bit-identical for `random_seed`.

### 6.2 [P1] No verification that `analysis_name` is unique across HDF5
ModelArray will happily write an analysis under a duplicate name (overwriting prior results in the H5 group) and there is no `--no-clobber` guard.

### 6.3 [P2] No QC plot generation in the pipeline
[render_nifti_preview.sh](render_nifti_preview.sh) exists but is never called by `3_run_model.sh` or the batch runner. Users have no automated thumbnail of beta/t/p maps after a run.

---

## 7. Concurrency & State

### 7.1 [P1] GUI's `_job_lock` only protects bookkeeping, not the filesystem
[gui/app.py](gui/app.py#L43-L50) allows one job at a time *per process*, but spawning a second GUI on a different port (the auto-port logic) creates a second jobs surface that can write to the same `LOGS_DIR` and to the same output trees simultaneously. Also, `/run` with a long-running step + a user hitting `--force` regenerate on the same `cohort_*.csv` invites races.

**Fix:** advisory file lock (`flock`) on `<output_dir>/.modelarray.lock` for any write.

### 7.2 [P2] No back-pressure on `nohup` mode
A user can launch any number of `--nohup` jobs that all write to `/tmp/nohup_*.log` and to the same `OUTPUT_DIR`. Stage E uses `R_SCRIPT_PATH="$DATA_DIR/generated_script.R"` (fixed name → mutual corruption).

---

## 8. Documentation Lies / Omissions

### 8.1 [P2] README ([README.md](README.md)) shows a `--scalar icvf_dwimap` example but does not warn that the rerun reuses the existing `cohort_*.h5` even when `--force` is *not* passed
The cohort regen logic in [_run_scalar_pipeline.sh](_run_scalar_pipeline.sh#L330-L355) and `--force` semantics in [run_analysis.sh](run_analysis.sh#L189-L194) require reading three files to understand.

### 8.2 [P2] No documented invariants for the participants TSV
What columns are required (`participant_id`, `session`, `age@ses-N`, `group`, `sex`)? What are valid `group` values? How is `participant_id` formatted (`sub-XXXXXX` vs `sub-XXXXXX_ses-N`)? The shell scripts and `prepare_longitudinal_participants.sh` each assume something different.

**Fix:** a `docs/participants_schema.md` and a validator script.

### 8.3 [P3] `inspect_modelarray_h5.sh` and `render_nifti_preview.sh` are not referenced from the README

---

## 9. Suggested Roadmap (priority order)

| Order | Theme | Items | Outcome |
|------|-------|-------|---------|
| 1 | Lock down GUI | 1.1, 1.2, 1.3 | Safe to run on shared host |
| 2 | Stop silent data corruption | 2.1, 2.2, 3.3 | Trustworthy formulas; no in-place H5 mutation |
| 3 | Make pipeline failures loud | 2.7, 2.8, 2.9, 3.2, 3.6 | No more silent row drops / fuzzy file picks |
| 4 | Provenance + tests | 5.1, 6.1, 6.2 | Repeatable, auditable runs |
| 5 | Config schema + canonical key | 4.1, 4.2 | One config shape, validated up-front |
| 6 | ML correctness | 2.3, 2.4, 2.5, 4.3 | Labels round-trip; NaN policy explicit |
| 7 | Reduce hardcoded paths | 1.4, 3.7 | Portable to other datasets/hosts |
| 8 | Polish | 3.1, 3.4, 3.5, 4.4, 5.2, 5.3, 5.4, 6.3, 7.x, 8.x | Operational quality of life |

---

*Generated as a hostile review; treat every "P0/P1" as a real risk to validated science output until proven otherwise on a small synthetic fixture.*
