# Toxicity prediction model (Module 3 ML part)

This folder contains the ML implementation for wallet-level toxicity prediction.

## Files

- `toxicity_model.py`  
  End-to-end training/evaluation script.
- `wallet_toxicity_frame.csv`  
  Training frame (one row per counterparty) with early-window features and late-window labels.
- `toxicity_model_results.json`  
  Metrics from the latest run.

## What the script does

1. Loads `wallet_toxicity_frame.csv` if it already exists, or rebuilds it from `notebook_data.npz`.
2. Reproduces the baseline classifier from the notebook (rank by `mean_mo60_early`).
3. Trains an ensemble model (logistic regression + gradient boosting + random forest).
4. Reports:
   - wallet-level random split AUC (`>=10`, `>=50`, `>=100` fills),
   - holdout-coin AUC (train BTC/test ETH and train ETH/test BTC).

## Run

From repository root:

```bash
python3 ml/toxicity_model.py --rebuild-frame
```

If `wallet_toxicity_frame.csv` already exists and you only want to train/evaluate:

```bash
python3 ml/toxicity_model.py
```

## Baseline vs model (latest run)

- `>=10` fills: baseline AUC `0.510` -> model AUC `0.545` (`+0.036`)
- `>=50` fills: baseline AUC `0.555` -> model AUC `0.635` (`+0.080`)
- `>=100` fills: baseline AUC `0.610` -> model AUC `0.676` (`+0.066`)

The model beats the baseline ranking in all reported settings.
