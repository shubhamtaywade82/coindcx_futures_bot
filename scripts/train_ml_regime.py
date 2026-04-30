#!/usr/bin/env python3
"""
Train a multinomial logistic regime classifier and emit a JSON bundle consumed by
CoindcxBot::Regime::MlModelBundle (schema_version 1).

Input CSV (no header): six z-scored feature columns matching Ruby Regime::Features indexed row order
(std20, vol_ratio, rsi/100 proxy column, atr_rel, roc10 clamped, vol_z), then integer label 0..K-1.

Example:
  python3 scripts/train_ml_regime.py --csv training_rows.csv --out data/ml_regime_model.json \\
    --classes calm,trend,volatile --tiers low_vol,mid_vol,high_vol

Requires: pip install scikit-learn pandas
"""
from __future__ import annotations

import argparse
import json
import sys

try:
    import pandas as pd
    from sklearn.linear_model import LogisticRegression
except ImportError:
    print("Install dependencies: pip install scikit-learn pandas", file=sys.stderr)
    sys.exit(1)


FEATURE_ORDER = ["std20", "vol_ratio", "rsi_norm", "atr_rel", "roc10", "vol_z"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True, help="CSV with 6 floats + label column (no header)")
    ap.add_argument("--out", required=True, help="Output JSON path for Ruby loader")
    ap.add_argument("--classes", required=True, help="Comma class names, same order as labels 0..K-1")
    ap.add_argument("--tiers", required=True, help="Comma tiers (low_vol|mid_vol|high_vol), one per class")
    args = ap.parse_args()

    class_names = [s.strip() for s in args.classes.split(",") if s.strip()]
    tiers = [s.strip() for s in args.tiers.split(",") if s.strip()]
    if len(class_names) != len(tiers):
        raise SystemExit("classes and tiers must have the same length")

    df = pd.read_csv(args.csv, header=None)
    if df.shape[1] != 7:
        raise SystemExit(f"expected 7 columns (6 features + label), got {df.shape[1]}")

    x = df.iloc[:, :6].values
    y = df.iloc[:, 6].astype(int).values
    clf = LogisticRegression(max_iter=500, multi_class="multinomial")
    clf.fit(x, y)

    tier_by_class = {class_names[i]: tiers[i] for i in range(len(class_names))}
    bundle = {
        "schema_version": 1,
        "model_type": "multinomial_logistic",
        "feature_order": FEATURE_ORDER,
        "classes": class_names,
        "weights": clf.coef_.tolist(),
        "biases": clf.intercept_.tolist(),
        "tier_by_class": tier_by_class,
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(bundle, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
