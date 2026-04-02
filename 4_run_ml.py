#!/usr/bin/env python3

import argparse
import inspect
import json
import sys
import warnings
from datetime import datetime
from pathlib import Path


def ts(message: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}")


def fail(message: str, code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def resolve_data_path(data_dir: Path, maybe_relative: str) -> Path:
    p = Path(maybe_relative)
    if p.is_absolute():
        return p
    return data_dir / p


def load_dependencies():
    missing = []
    try:
        import h5py  # noqa: F401
    except Exception:
        missing.append("h5py")

    try:
        import numpy as np  # noqa: F401
    except Exception:
        missing.append("numpy")

    try:
        import pandas as pd  # noqa: F401
    except Exception:
        missing.append("pandas")

    try:
        import sklearn  # noqa: F401
    except Exception:
        missing.append("scikit-learn")

    if missing:
        fail(
            "Missing Python dependencies for ML stage: "
            + ", ".join(missing)
            + ". Install with: python3 -m pip install "
            + " ".join(missing)
        )

    import h5py
    import numpy as np
    import pandas as pd
    from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
    from sklearn.linear_model import ElasticNetCV, LogisticRegressionCV
    from sklearn.metrics import (
        accuracy_score,
        balanced_accuracy_score,
        f1_score,
        mean_absolute_error,
        mean_squared_error,
        r2_score,
        roc_auc_score,
    )
    from sklearn.exceptions import ConvergenceWarning
    from sklearn.model_selection import GroupKFold, KFold, StratifiedKFold
    from sklearn.pipeline import Pipeline
    from sklearn.impute import SimpleImputer
    from sklearn.preprocessing import LabelEncoder, StandardScaler
    from sklearn.svm import SVC, SVR

    return {
        "h5py": h5py,
        "np": np,
        "pd": pd,
        "RandomForestClassifier": RandomForestClassifier,
        "RandomForestRegressor": RandomForestRegressor,
        "ElasticNetCV": ElasticNetCV,
        "LogisticRegressionCV": LogisticRegressionCV,
        "accuracy_score": accuracy_score,
        "balanced_accuracy_score": balanced_accuracy_score,
        "f1_score": f1_score,
        "mean_absolute_error": mean_absolute_error,
        "mean_squared_error": mean_squared_error,
        "r2_score": r2_score,
        "roc_auc_score": roc_auc_score,
        "ConvergenceWarning": ConvergenceWarning,
        "GroupKFold": GroupKFold,
        "KFold": KFold,
        "StratifiedKFold": StratifiedKFold,
        "Pipeline": Pipeline,
        "SimpleImputer": SimpleImputer,
        "LabelEncoder": LabelEncoder,
        "StandardScaler": StandardScaler,
        "SVC": SVC,
        "SVR": SVR,
    }


def normalize_models(raw_models):
    aliases = {
        "rf": "random_forest",
        "random_forest": "random_forest",
        "svm": "svm_rbf",
        "svm_rbf": "svm_rbf",
        "elastic_net": "elastic_net",
        "enet": "elastic_net",
        "xgb": "xgboost",
        "xgboost": "xgboost",
    }

    if not raw_models:
        return ["random_forest", "svm_rbf", "elastic_net"]

    normalized = []
    for name in raw_models:
        key = str(name).strip().lower()
        if key not in aliases:
            fail(
                f"Unsupported ML model '{name}'. Supported: random_forest, svm_rbf, elastic_net, xgboost"
            )
        canonical = aliases[key]
        if canonical not in normalized:
            normalized.append(canonical)

    return normalized


def build_estimator(model_name, task, model_params, seed, n_jobs, deps, n_classes):
    RandomForestClassifier = deps["RandomForestClassifier"]
    RandomForestRegressor = deps["RandomForestRegressor"]
    ElasticNetCV = deps["ElasticNetCV"]
    LogisticRegressionCV = deps["LogisticRegressionCV"]
    SVC = deps["SVC"]
    SVR = deps["SVR"]

    params = dict(model_params.get(model_name, {}))

    if model_name == "random_forest":
        if task == "classification":
            defaults = {
                "n_estimators": 500,
                "class_weight": "balanced",
                "random_state": seed,
                "n_jobs": n_jobs,
            }
            defaults.update(params)
            return RandomForestClassifier(**defaults)

        defaults = {
            "n_estimators": 500,
            "random_state": seed,
            "n_jobs": n_jobs,
        }
        defaults.update(params)
        return RandomForestRegressor(**defaults)

    if model_name == "svm_rbf":
        if task == "classification":
            defaults = {
                "kernel": "rbf",
                "C": 1.0,
                "gamma": "scale",
                "probability": True,
                "class_weight": "balanced",
            }
            defaults.update(params)
            return SVC(**defaults)

        defaults = {
            "kernel": "rbf",
            "C": 1.0,
            "gamma": "scale",
        }
        defaults.update(params)
        return SVR(**defaults)

    if model_name == "elastic_net":
        if task == "classification":
            defaults = {
                "solver": "saga",
                "l1_ratios": [0.1, 0.5, 0.9],
                "Cs": 10,
                "cv": 3,
                "class_weight": "balanced",
                "max_iter": 5000,
                "n_jobs": n_jobs,
                "random_state": seed,
            }
            if (
                "use_legacy_attributes" in inspect.signature(LogisticRegressionCV).parameters
                and "use_legacy_attributes" not in params
            ):
                defaults["use_legacy_attributes"] = False
            if n_classes <= 2:
                defaults["scoring"] = "roc_auc"
            else:
                defaults["scoring"] = "roc_auc_ovr_weighted"
            defaults.update(params)
            return LogisticRegressionCV(**defaults)

        defaults = {
            "l1_ratio": [0.1, 0.5, 0.9, 0.95, 0.99, 1.0],
            "cv": 3,
            "random_state": seed,
            "n_jobs": n_jobs,
        }
        defaults.update(params)
        return ElasticNetCV(**defaults)

    if model_name == "xgboost":
        try:
            import xgboost as xgb
        except Exception:
            fail(
                "Model 'xgboost' was requested, but the xgboost package is not installed. "
                "Install with: python3 -m pip install xgboost"
            )

        if task == "classification":
            defaults = {
                "n_estimators": 400,
                "learning_rate": 0.05,
                "max_depth": 4,
                "subsample": 0.8,
                "colsample_bytree": 0.8,
                "reg_lambda": 1.0,
                "random_state": seed,
                "n_jobs": n_jobs,
                "eval_metric": "logloss",
            }
            if n_classes > 2:
                defaults["objective"] = "multi:softprob"
                defaults["num_class"] = int(n_classes)
            else:
                defaults["objective"] = "binary:logistic"
            defaults.update(params)
            return xgb.XGBClassifier(**defaults)

        defaults = {
            "n_estimators": 400,
            "learning_rate": 0.05,
            "max_depth": 4,
            "subsample": 0.8,
            "colsample_bytree": 0.8,
            "reg_lambda": 1.0,
            "random_state": seed,
            "n_jobs": n_jobs,
            "objective": "reg:squarederror",
        }
        defaults.update(params)
        return xgb.XGBRegressor(**defaults)

    fail(f"Unhandled model name: {model_name}")


def build_splitter(task, y_series, groups_series, n_splits, seed, deps):
    pd = deps["pd"]
    StratifiedKFold = deps["StratifiedKFold"]
    GroupKFold = deps["GroupKFold"]
    KFold = deps["KFold"]

    if groups_series is not None:
        n_groups = groups_series.nunique()
        if n_groups < 2:
            fail("group_column has fewer than 2 unique groups; grouped CV is not possible.")
        n_splits = min(max(2, int(n_splits)), int(n_groups))

        if task == "classification":
            try:
                from sklearn.model_selection import StratifiedGroupKFold

                return StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=seed), n_splits
            except Exception:
                ts("StratifiedGroupKFold unavailable; falling back to GroupKFold.")

        return GroupKFold(n_splits=n_splits), n_splits

    if task == "classification":
        class_counts = y_series.value_counts()
        min_class_n = int(class_counts.min())
        if min_class_n < 2:
            fail("At least 2 samples per class are required for classification CV.")
        n_splits = min(max(2, int(n_splits)), min_class_n)
        return StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=seed), n_splits

    n_splits = min(max(2, int(n_splits)), len(y_series))
    return KFold(n_splits=n_splits, shuffle=True, random_state=seed), n_splits


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Stage 4 pattern-recognition ML on ModelArray H5 matrices"
    )
    parser.add_argument("config", help="Path to scalar-level JSON config")
    args = parser.parse_args()

    config_path = Path(args.config).resolve()
    if not config_path.is_file():
        fail(f"Config not found: {config_path}")

    with config_path.open("r", encoding="utf-8") as f:
        config = json.load(f)

    ml = config.get("ml", {})
    if not ml.get("enabled", False):
        ts("ML stage disabled (ml.enabled is false).")
        return

    data_dir = Path(config.get("data_dir", "")).expanduser()
    if not str(data_dir):
        fail("data_dir is required in config.")
    if not data_dir.is_absolute():
        data_dir = (config_path.parent / data_dir).resolve()

    scalar = config.get("scaler_type", "")
    h5_file = config.get("h5_file", "")
    csv_file = config.get("csv_file", "")
    if not scalar:
        fail("scaler_type is required in config.")
    if not h5_file:
        fail("h5_file is required in config.")
    if not csv_file:
        fail("csv_file is required in config.")

    task = str(ml.get("task", "classification")).strip().lower()
    if task not in {"classification", "regression"}:
        fail("ml.task must be either 'classification' or 'regression'.")

    target_col = ml.get("target_column")
    if not target_col:
        fail("ml.target_column is required when ml.enabled is true.")

    group_col = ml.get("group_column")
    id_columns = ml.get("id_columns", [])
    if not isinstance(id_columns, list):
        fail("ml.id_columns must be an array of column names.")
    drop_missing_rows = bool(ml.get("drop_missing_rows", True))

    n_splits = int(ml.get("n_splits", 5))
    seed = int(ml.get("random_seed", 42))
    n_jobs = int(ml.get("n_jobs", -1))
    scale_features = bool(ml.get("scale_features", True))
    models = normalize_models(ml.get("models", []))
    model_params = ml.get("model_params", {})
    primary_metric = ml.get("primary_metric")
    suppress_future_warnings = bool(ml.get("suppress_future_warnings", False))
    suppress_convergence_warnings = bool(ml.get("suppress_convergence_warnings", False))

    output_root_default = Path(config.get("output_dir", "results")) / "ml"
    output_root = resolve_data_path(data_dir, ml.get("output_dir", str(output_root_default)))
    metrics_path = resolve_data_path(data_dir, ml.get("metrics_file", str(output_root / "metrics.csv")))
    predictions_path = resolve_data_path(
        data_dir, ml.get("predictions_file", str(output_root / "predictions.csv"))
    )
    summary_path = resolve_data_path(data_dir, ml.get("summary_file", str(output_root / "summary.json")))

    deps = load_dependencies()
    h5py = deps["h5py"]
    np = deps["np"]
    pd = deps["pd"]
    Pipeline = deps["Pipeline"]
    SimpleImputer = deps["SimpleImputer"]
    StandardScaler = deps["StandardScaler"]
    LabelEncoder = deps["LabelEncoder"]
    ConvergenceWarning = deps["ConvergenceWarning"]

    if suppress_future_warnings:
        warnings.filterwarnings(
            "ignore",
            category=FutureWarning,
            module=r"sklearn\.linear_model\._logistic",
        )
    if suppress_convergence_warnings:
        warnings.filterwarnings(
            "ignore",
            category=ConvergenceWarning,
            module=r"sklearn\.linear_model\._sag",
        )

    h5_path = resolve_data_path(data_dir, h5_file)
    cohort_path = resolve_data_path(data_dir, csv_file)

    if not h5_path.is_file():
        fail(f"H5 file not found: {h5_path}")
    if not cohort_path.is_file():
        fail(f"Cohort CSV not found: {cohort_path}")

    ts(f"Loading features from {h5_path}")
    with h5py.File(h5_path, "r") as h5:
        dataset_path = f"scalars/{scalar}/values"
        if dataset_path not in h5:
            available = sorted(list(h5.get("scalars", {}).keys()))
            fail(
                f"Dataset '{dataset_path}' not found in H5. Available scalars: {', '.join(available)}"
            )
        X = np.asarray(h5[dataset_path], dtype=np.float32)

    ts(f"Loading labels from {cohort_path}")
    cohort = pd.read_csv(cohort_path)
    cohort = cohort.reset_index(drop=True)
    cohort["_source_row_index"] = cohort.index

    if X.ndim != 2:
        fail(f"Feature matrix must be 2D, got shape {X.shape}")
    if len(cohort) != X.shape[0]:
        fail(
            f"Cohort rows ({len(cohort)}) do not match H5 subject rows ({X.shape[0]})."
        )
    if target_col not in cohort.columns:
        fail(f"Target column '{target_col}' not found in cohort CSV.")

    valid_mask = ~cohort[target_col].isna()

    if group_col:
        if group_col not in cohort.columns:
            fail(f"Group column '{group_col}' not found in cohort CSV.")
        valid_mask = valid_mask & (~cohort[group_col].isna())

    dropped_rows = int((~valid_mask).sum())
    if dropped_rows > 0:
        if not drop_missing_rows:
            fail(
                f"Found {dropped_rows} rows with missing target/group values. "
                "Set ml.drop_missing_rows=true to drop them automatically."
            )
        ts(f"Dropping {dropped_rows} rows with missing target/group values before CV.")
        cohort = cohort.loc[valid_mask].copy().reset_index(drop=True)
        X = X[valid_mask.to_numpy()]

    y_raw = cohort[target_col]

    if group_col:
        groups_series = cohort[group_col].astype(str)
    else:
        groups_series = None

    if task == "classification":
        y_series = y_raw.astype(str)
        n_classes = y_series.nunique()
        if n_classes < 2:
            fail("Classification requires at least two classes in target_column.")
    else:
        y_series = pd.to_numeric(y_raw, errors="coerce")
        if y_series.isna().any():
            fail("Regression target contains non-numeric values.")
        n_classes = 0

    splitter, n_splits = build_splitter(task, y_series, groups_series, n_splits, seed, deps)

    metrics_rows = []
    pred_rows = []

    ts(
        "Starting ML CV on "
        f"{scalar}: {X.shape[0]} subjects x {X.shape[1]} voxels, "
        f"task={task}, models={','.join(models)}, folds={n_splits}"
    )

    if groups_series is not None:
        split_iter = splitter.split(X, y_series, groups_series)
    else:
        split_iter = splitter.split(X, y_series)

    folds = list(split_iter)
    if len(folds) < 2:
        fail("Cross-validation produced fewer than 2 folds.")

    accuracy_score = deps["accuracy_score"]
    balanced_accuracy_score = deps["balanced_accuracy_score"]
    f1_score = deps["f1_score"]
    roc_auc_score = deps["roc_auc_score"]
    r2_score = deps["r2_score"]
    mean_absolute_error = deps["mean_absolute_error"]
    mean_squared_error = deps["mean_squared_error"]

    for model_name in models:
        ts(f"Model: {model_name}")

        estimator = build_estimator(
            model_name=model_name,
            task=task,
            model_params=model_params if isinstance(model_params, dict) else {},
            seed=seed,
            n_jobs=n_jobs,
            deps=deps,
            n_classes=n_classes,
        )

        use_scaler = scale_features and model_name in {"svm_rbf", "elastic_net"}
        needs_imputer = model_name in {"svm_rbf", "elastic_net"}
        if use_scaler or needs_imputer:
            steps = []
            if needs_imputer:
                steps.append(("impute", SimpleImputer(strategy="mean")))
            if use_scaler:
                steps.append(("scale", StandardScaler()))
            steps.append(("model", estimator))
            model = Pipeline(steps)
        else:
            model = estimator

        label_encoder = None
        if task == "classification" and model_name == "xgboost":
            label_encoder = LabelEncoder()
            label_encoder.fit(y_series)

        for fold_idx, (train_idx, test_idx) in enumerate(folds, start=1):
            X_train = X[train_idx]
            X_test = X[test_idx]
            y_train = y_series.iloc[train_idx]
            y_test = y_series.iloc[test_idx]

            if label_encoder is not None:
                y_train_fit = label_encoder.transform(y_train)
                model.fit(X_train, y_train_fit)
                y_pred = label_encoder.inverse_transform(model.predict(X_test).astype(int))
            else:
                model.fit(X_train, y_train)
                y_pred = model.predict(X_test)

            metric_row = {
                "model": model_name,
                "fold": fold_idx,
                "n_train": int(len(train_idx)),
                "n_test": int(len(test_idx)),
            }

            if task == "classification":
                metric_row["accuracy"] = float(accuracy_score(y_test, y_pred))
                metric_row["balanced_accuracy"] = float(balanced_accuracy_score(y_test, y_pred))
                metric_row["f1_weighted"] = float(f1_score(y_test, y_pred, average="weighted"))

                proba = None
                if hasattr(model, "predict_proba"):
                    proba = model.predict_proba(X_test)
                elif isinstance(model, Pipeline) and hasattr(model.named_steps["model"], "predict_proba"):
                    proba = model.predict_proba(X_test)

                if proba is not None:
                    if n_classes == 2:
                        metric_row["roc_auc"] = float(roc_auc_score(y_test, proba[:, 1]))
                    else:
                        metric_row["roc_auc_ovr_weighted"] = float(
                            roc_auc_score(y_test, proba, multi_class="ovr", average="weighted")
                        )

                for local_i, row_idx in enumerate(test_idx):
                    row = {
                        "model": model_name,
                        "fold": fold_idx,
                        "row_index": int(cohort.iloc[row_idx]["_source_row_index"]),
                        "y_true": str(y_test.iloc[local_i]),
                        "y_pred": str(y_pred[local_i]),
                    }
                    if proba is not None:
                        row["pred_confidence"] = float(np.max(proba[local_i]))
                    for col in id_columns:
                        if col in cohort.columns:
                            row[col] = cohort.iloc[row_idx][col]
                    pred_rows.append(row)
            else:
                y_test_np = y_test.to_numpy(dtype=float)
                y_pred_np = np.asarray(y_pred, dtype=float)
                metric_row["r2"] = float(r2_score(y_test_np, y_pred_np))
                metric_row["mae"] = float(mean_absolute_error(y_test_np, y_pred_np))
                metric_row["rmse"] = float(np.sqrt(mean_squared_error(y_test_np, y_pred_np)))

                for local_i, row_idx in enumerate(test_idx):
                    row = {
                        "model": model_name,
                        "fold": fold_idx,
                        "row_index": int(cohort.iloc[row_idx]["_source_row_index"]),
                        "y_true": float(y_test_np[local_i]),
                        "y_pred": float(y_pred_np[local_i]),
                    }
                    for col in id_columns:
                        if col in cohort.columns:
                            row[col] = cohort.iloc[row_idx][col]
                    pred_rows.append(row)

            metrics_rows.append(metric_row)

    metrics_df = pd.DataFrame(metrics_rows)
    preds_df = pd.DataFrame(pred_rows)

    if metrics_df.empty:
        fail("No ML metrics were produced.")

    metric_cols = [
        c for c in metrics_df.columns if c not in {"model", "fold", "n_train", "n_test"}
    ]

    summary_rows = []
    for model_name, g in metrics_df.groupby("model", sort=False):
        row = {"model": model_name}
        for m in metric_cols:
            vals = g[m].dropna()
            if len(vals) == 0:
                continue
            row[f"{m}_mean"] = float(vals.mean())
            row[f"{m}_std"] = float(vals.std(ddof=0))
        summary_rows.append(row)

    summary_df = pd.DataFrame(summary_rows)

    if task == "classification":
        if not primary_metric:
            primary_metric = (
                "roc_auc_ovr_weighted"
                if "roc_auc_ovr_weighted_mean" in summary_df.columns
                else "balanced_accuracy"
            )
    else:
        if not primary_metric:
            primary_metric = "r2"

    primary_mean_col = f"{primary_metric}_mean"
    if primary_mean_col not in summary_df.columns:
        fail(
            f"Primary metric '{primary_metric}' is not available. Available metrics: "
            + ", ".join(metric_cols)
        )

    maximize = primary_metric not in {"mae", "rmse"}
    ranked = summary_df.sort_values(primary_mean_col, ascending=not maximize).reset_index(drop=True)
    best_model = str(ranked.iloc[0]["model"])

    output_root.mkdir(parents=True, exist_ok=True)
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    predictions_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    metrics_df.to_csv(metrics_path, index=False)
    preds_df.to_csv(predictions_path, index=False)

    summary_payload = {
        "config": {
            "task": task,
            "target_column": target_col,
            "group_column": group_col,
            "models": models,
            "n_splits": n_splits,
            "random_seed": seed,
            "scale_features": scale_features,
            "suppress_future_warnings": suppress_future_warnings,
            "suppress_convergence_warnings": suppress_convergence_warnings,
            "primary_metric": primary_metric,
        },
        "data": {
            "scalar": scalar,
            "n_subjects": int(X.shape[0]),
            "n_features": int(X.shape[1]),
            "h5_file": str(h5_path),
            "csv_file": str(cohort_path),
        },
        "best_model": best_model,
        "summary_rows": summary_rows,
    }

    with summary_path.open("w", encoding="utf-8") as f:
        json.dump(summary_payload, f, indent=2)

    ts(f"Primary metric: {primary_metric} ({'max' if maximize else 'min'})")
    ts(f"Best model: {best_model}")
    ts(f"Wrote metrics: {metrics_path}")
    ts(f"Wrote predictions: {predictions_path}")
    ts(f"Wrote summary: {summary_path}")


if __name__ == "__main__":
    main()
