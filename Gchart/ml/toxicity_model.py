#!/usr/bin/env python3
"""Train and evaluate a counterparty-toxicity model.

This script supports the workflow described in the capstone notebook:
1) Build/load wallet-level training data (early-window features, late-window labels)
2) Reproduce the baseline AUC (rank by mean_mo60_early)
3) Train a stronger non-linear classifier and report out-of-sample AUC
4) Evaluate both wallet splits and holdout-coin generalization to reduce leakage risk
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
import urllib.request

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier, VotingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedShuffleSplit
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

EARLY_DAYS = (4, 5, 6, 7, 8)
LATE_DAYS = (9, 10, 11, 12, 13)

FEATURE_COLUMNS = [
    "fills_early",
    "mean_mo60_early",
    "std_mo60_early",
    "mean_notional_early",
    "mean_imb_early",
    "mean_start_pos_early",
]
LABEL_COLUMN = "label_toxic_late"

ZENODO = "https://zenodo.org/records/21171473/files/"
NPZ_FILENAME = "notebook_data.npz"


def _download_if_missing(url: str, target_path: Path) -> None:
    if target_path.exists():
        return
    target_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"[download] {url} -> {target_path}")
    urllib.request.urlretrieve(url, target_path.as_posix())


def _build_coin_frame(df: pd.DataFrame, coin_code: int, coin_name: str) -> pd.DataFrame:
    coin_df = df[df["coin"] == coin_code]

    early = coin_df[coin_df["day"].isin(EARLY_DAYS)]
    early = early[np.isfinite(early["mo60"])]
    early_stats = (
        early.groupby("taker", sort=False)
        .agg(
            fills_early=("taker", "size"),
            mean_mo60_early=("mo60", "mean"),
            std_mo60_early=("mo60", "std"),
            mean_notional_early=("notional", "mean"),
            mean_imb_early=("imb_entry", "mean"),
            mean_start_pos_early=("start_pos", "mean"),
        )
        .astype(float)
    )

    late = coin_df[coin_df["day"].isin(LATE_DAYS)]
    late = late[np.isfinite(late["mo60"])]
    late_stats = (
        late.groupby("taker", sort=False)
        .agg(label_mo60_late=("mo60", "mean"))
        .astype(float)
    )

    out = early_stats.join(late_stats, how="inner")
    out = out.reset_index().rename(columns={"taker": "wallet"})
    out["coin"] = coin_name
    out["std_mo60_early"] = out["std_mo60_early"].fillna(0.0)
    out[LABEL_COLUMN] = (out["label_mo60_late"] > 0.0).astype(int)
    return out


def build_wallet_frame_from_npz(npz_path: Path, frame_csv_path: Path) -> pd.DataFrame:
    arr = np.load(npz_path)
    df = pd.DataFrame(
        {
            "taker": arr["taker_code"].astype(np.int64),
            "coin": arr["coin"].astype(np.int64),
            "day": arr["day"].astype(np.int64),
            "notional": arr["notional"].astype(float),
            "start_pos": arr["start_pos"].astype(float),
            "mo60": arr["mo60"].astype(float),
            "imb_entry": arr["imb_entry"].astype(float),
        }
    )
    df = df.replace([np.inf, -np.inf], np.nan)

    btc = _build_coin_frame(df, 0, "BTC")
    eth = _build_coin_frame(df, 1, "ETH")
    frame = pd.concat([btc, eth], ignore_index=True)
    frame = frame[
        [
            "wallet",
            "coin",
            *FEATURE_COLUMNS,
            "label_mo60_late",
            LABEL_COLUMN,
        ]
    ]
    frame.sort_values(["coin", "wallet"], inplace=True, ignore_index=True)
    frame_csv_path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(frame_csv_path, index=False)
    print(f"[frame] wrote {len(frame):,} rows -> {frame_csv_path}")
    return frame


def load_or_build_frame(frame_csv_path: Path, npz_path: Path, force_rebuild: bool) -> pd.DataFrame:
    if frame_csv_path.exists() and not force_rebuild:
        frame = pd.read_csv(frame_csv_path)
        print(f"[frame] loaded existing frame: {len(frame):,} rows from {frame_csv_path}")
        return frame

    _download_if_missing(f"{ZENODO}{NPZ_FILENAME}?download=1", npz_path)
    return build_wallet_frame_from_npz(npz_path=npz_path, frame_csv_path=frame_csv_path)


def build_ensemble_model(seed: int) -> VotingClassifier:
    logistic = Pipeline(
        steps=[
            ("imputer", SimpleImputer(strategy="median")),
            ("scaler", StandardScaler()),
            (
                "model",
                LogisticRegression(
                    max_iter=2500,
                    class_weight="balanced",
                    random_state=seed,
                ),
            ),
        ]
    )
    hgb = Pipeline(
        steps=[
            ("imputer", SimpleImputer(strategy="median")),
            (
                "model",
                HistGradientBoostingClassifier(
                    max_depth=4,
                    max_iter=300,
                    learning_rate=0.05,
                    min_samples_leaf=24,
                    random_state=seed,
                ),
            ),
        ]
    )
    rf = Pipeline(
        steps=[
            ("imputer", SimpleImputer(strategy="median")),
            (
                "model",
                RandomForestClassifier(
                    n_estimators=320,
                    max_depth=10,
                    min_samples_leaf=10,
                    class_weight="balanced_subsample",
                    n_jobs=-1,
                    random_state=seed,
                ),
            ),
        ]
    )
    return VotingClassifier(
        estimators=[("logreg", logistic), ("hgb", hgb), ("rf", rf)],
        voting="soft",
        n_jobs=-1,
    )


def _safe_auc(y_true: np.ndarray, score: np.ndarray) -> float:
    if np.unique(y_true).size < 2:
        return float("nan")
    return float(roc_auc_score(y_true, score))


def evaluate_wallet_split(
    frame: pd.DataFrame,
    min_fills: int,
    n_splits: int,
    test_size: float,
    seed: int,
) -> dict[str, Any]:
    subset = frame[frame["fills_early"] >= min_fills].copy()
    y = subset[LABEL_COLUMN].to_numpy(dtype=int)
    X = subset[FEATURE_COLUMNS]
    baseline_scores = subset["mean_mo60_early"].fillna(0.0).to_numpy(dtype=float)

    if len(subset) < 100 or np.unique(y).size < 2:
        return {"n": int(len(subset)), "baseline_auc_mean": float("nan"), "model_auc_mean": float("nan")}

    splitter = StratifiedShuffleSplit(n_splits=n_splits, test_size=test_size, random_state=seed)
    baseline_aucs: list[float] = []
    model_aucs: list[float] = []
    for split_idx, (train_idx, test_idx) in enumerate(splitter.split(X, y)):
        model = build_ensemble_model(seed + split_idx)
        model.fit(X.iloc[train_idx], y[train_idx])
        pred = model.predict_proba(X.iloc[test_idx])[:, 1]
        model_aucs.append(_safe_auc(y[test_idx], pred))
        baseline_aucs.append(_safe_auc(y[test_idx], baseline_scores[test_idx]))

    return {
        "n": int(len(subset)),
        "positive_rate": float(y.mean()),
        "baseline_auc_mean": float(np.nanmean(baseline_aucs)),
        "baseline_auc_std": float(np.nanstd(baseline_aucs)),
        "model_auc_mean": float(np.nanmean(model_aucs)),
        "model_auc_std": float(np.nanstd(model_aucs)),
        "improvement": float(np.nanmean(model_aucs) - np.nanmean(baseline_aucs)),
    }


def evaluate_holdout_coin(frame: pd.DataFrame, min_fills: int, seed: int) -> dict[str, dict[str, float]]:
    subset = frame[frame["fills_early"] >= min_fills].copy()
    out: dict[str, dict[str, float]] = {}
    for train_coin, test_coin in (("BTC", "ETH"), ("ETH", "BTC")):
        train = subset[subset["coin"] == train_coin]
        test = subset[subset["coin"] == test_coin]
        key = f"{train_coin}_to_{test_coin}"

        if len(train) < 100 or len(test) < 100:
            out[key] = {"n_train": int(len(train)), "n_test": int(len(test)), "baseline_auc": float("nan"), "model_auc": float("nan")}
            continue
        y_train = train[LABEL_COLUMN].to_numpy(dtype=int)
        y_test = test[LABEL_COLUMN].to_numpy(dtype=int)
        if np.unique(y_train).size < 2 or np.unique(y_test).size < 2:
            out[key] = {"n_train": int(len(train)), "n_test": int(len(test)), "baseline_auc": float("nan"), "model_auc": float("nan")}
            continue

        model = build_ensemble_model(seed)
        model.fit(train[FEATURE_COLUMNS], y_train)
        pred = model.predict_proba(test[FEATURE_COLUMNS])[:, 1]
        out[key] = {
            "n_train": int(len(train)),
            "n_test": int(len(test)),
            "baseline_auc": _safe_auc(y_test, test["mean_mo60_early"].fillna(0.0).to_numpy(dtype=float)),
            "model_auc": _safe_auc(y_test, pred),
            "improvement": _safe_auc(y_test, pred)
            - _safe_auc(y_test, test["mean_mo60_early"].fillna(0.0).to_numpy(dtype=float)),
        }
    return out


def print_results(results: dict[str, Any]) -> None:
    print("\n=== Toxicity model results ===")
    print(f"rows: {results['frame_rows']:,} | positive label rate: {results['positive_rate']:.3f}")
    print("\nWallet split (stratified random split by row)")
    for cut, metrics in results["wallet_split"].items():
        print(
            f"  >= {cut:>3} fills | n={metrics['n']:>5,} | "
            f"baseline AUC={metrics['baseline_auc_mean']:.3f} +/- {metrics['baseline_auc_std']:.3f} | "
            f"model AUC={metrics['model_auc_mean']:.3f} +/- {metrics['model_auc_std']:.3f} | "
            f"delta={metrics['improvement']:+.3f}"
        )

    print("\nHoldout coin (train one coin, test the other)")
    for cut, by_coin in results["holdout_coin"].items():
        print(f"  cutoff >= {cut} fills")
        for k, metrics in by_coin.items():
            print(
                f"    {k:>10} | n_train={metrics['n_train']:>5,}, n_test={metrics['n_test']:>5,} | "
                f"baseline={metrics['baseline_auc']:.3f} | model={metrics['model_auc']:.3f} | "
                f"delta={metrics['improvement']:+.3f}"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train/evaluate toxicity model on wallet frame data.")
    parser.add_argument(
        "--frame-csv",
        type=Path,
        default=Path("ml/wallet_toxicity_frame.csv"),
        help="Path to wallet_toxicity_frame.csv",
    )
    parser.add_argument(
        "--npz-path",
        type=Path,
        default=Path("ml/notebook_data.npz"),
        help="Path to notebook_data.npz used to rebuild frame when CSV is missing.",
    )
    parser.add_argument(
        "--rebuild-frame",
        action="store_true",
        help="Force rebuilding frame from notebook_data.npz even if CSV exists.",
    )
    parser.add_argument(
        "--wallet-split-cutoffs",
        type=int,
        nargs="+",
        default=[10, 50, 100],
        help="Early-fill minimums for wallet split evaluation.",
    )
    parser.add_argument(
        "--holdout-cutoffs",
        type=int,
        nargs="+",
        default=[50, 100],
        help="Early-fill minimums for holdout-coin evaluation.",
    )
    parser.add_argument("--seed", type=int, default=42, help="Random seed.")
    parser.add_argument("--n-splits", type=int, default=5, help="Number of random wallet splits.")
    parser.add_argument("--test-size", type=float, default=0.25, help="Test size for random wallet splits.")
    parser.add_argument(
        "--results-json",
        type=Path,
        default=Path("ml/toxicity_model_results.json"),
        help="Where to write results JSON.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    frame = load_or_build_frame(
        frame_csv_path=args.frame_csv,
        npz_path=args.npz_path,
        force_rebuild=args.rebuild_frame,
    )

    frame = frame.replace([np.inf, -np.inf], np.nan)
    frame["coin"] = frame["coin"].astype(str)
    frame[LABEL_COLUMN] = frame[LABEL_COLUMN].astype(int)

    results: dict[str, Any] = {
        "frame_rows": int(len(frame)),
        "positive_rate": float(frame[LABEL_COLUMN].mean()),
        "feature_columns": FEATURE_COLUMNS,
        "wallet_split": {},
        "holdout_coin": {},
    }

    for cut in args.wallet_split_cutoffs:
        results["wallet_split"][str(cut)] = evaluate_wallet_split(
            frame=frame,
            min_fills=cut,
            n_splits=args.n_splits,
            test_size=args.test_size,
            seed=args.seed,
        )

    for cut in args.holdout_cutoffs:
        results["holdout_coin"][str(cut)] = evaluate_holdout_coin(frame=frame, min_fills=cut, seed=args.seed)

    print_results(results)

    args.results_json.parent.mkdir(parents=True, exist_ok=True)
    with args.results_json.open("w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)
    print(f"\n[results] wrote {args.results_json}")


if __name__ == "__main__":
    main()
