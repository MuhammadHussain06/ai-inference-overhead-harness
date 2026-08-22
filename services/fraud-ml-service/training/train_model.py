import argparse
import os

import joblib
import numpy as np
import pandas as pd
import xgboost as xgb
from imblearn.over_sampling import SMOTE
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix
from sklearn.model_selection import train_test_split

MODELS_DIR = os.path.join(os.path.dirname(__file__), "..", "models")

ALL_V_COLUMNS = [f"V{i}" for i in range(1, 29)]


def output_path(n_features: int) -> str:
    return os.path.join(MODELS_DIR, f"fraud_model_v{n_features}.joblib")


def load_real_data(n_features: int):
    csv_path = os.path.join(os.path.dirname(__file__), "data", "creditcard.csv")
    df = pd.read_csv(csv_path)
    df["Amount"] = np.log1p(df["Amount"])
    columns = ALL_V_COLUMNS[:n_features] + ["Amount"]
    return df[columns], df["Class"]


def make_synthetic_data(n_features: int, n=20000, seed=42):
    rng = np.random.default_rng(seed)
    v_columns = ALL_V_COLUMNS[:n_features]
    X = pd.DataFrame(rng.normal(size=(n, n_features)), columns=v_columns)
    amount = rng.lognormal(mean=3.0, sigma=1.2, size=n)
    X["Amount"] = np.log1p(amount)
    # Rare synthetic "fraud" signal: large |V1| combined with large amount.
    score = X["V1"].abs() * 0.6 + X["Amount"] * 0.4
    threshold = np.quantile(score, 0.98)  # ~2% positive rate, similar to real dataset
    y = (score > threshold).astype(int)
    return X, y


def train_one(n_features: int, synthetic: bool):
    if synthetic:
        print(f"[*] v{n_features}: using synthetic data (smoke-test only)")
        X, y = make_synthetic_data(n_features)
    else:
        print(f"[*] v{n_features}: loading data/creditcard.csv")
        X, y = load_real_data(n_features)

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )

    smote = SMOTE(random_state=42)
    X_train_balanced, y_train_balanced = smote.fit_resample(X_train, y_train)

    model = xgb.XGBClassifier(max_depth=4, learning_rate=0.1)
    model.fit(X_train_balanced, y_train_balanced)

    print(f"[v{n_features}] Original Fraud Cases: {sum(y_train == 1)}")
    print(f"[v{n_features}] New Fraud Cases (post-SMOTE): {sum(y_train_balanced == 1)}")

    y_pred = model.predict(X_test)
    print(f"[v{n_features}] Accuracy Score: {accuracy_score(y_test, y_pred):.4f}")
    print(f"[v{n_features}] Confusion Matrix")
    print(confusion_matrix(y_test, y_pred))
    print(f"[v{n_features}] Classification Report:")
    print(classification_report(y_test, y_pred))

    os.makedirs(MODELS_DIR, exist_ok=True)
    path = output_path(n_features)
    joblib.dump(model, path)
    print(f"[v{n_features}] Model saved to {path}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--synthetic", action="store_true",
        help="Train on generated data instead of data/creditcard.csv"
    )
    parser.add_argument(
        "--n-features", type=int, default=None, choices=[5, 10, 20, 28],
        help="Train a single tier only (default: train all of 5,10,20,28)"
    )
    args = parser.parse_args()

    tiers = [args.n_features] if args.n_features else [5, 10, 20, 28]
    for n in tiers:
        train_one(n, args.synthetic)


if __name__ == "__main__":
    main()