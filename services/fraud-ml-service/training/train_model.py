
import argparse
import os

import joblib
import numpy as np
import pandas as pd
import xgboost as xgb
from imblearn.over_sampling import SMOTE
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix
from sklearn.model_selection import train_test_split

OUTPUT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "models", "fraud_model.joblib"
)


def load_real_data():
    csv_path = os.path.join(os.path.dirname(__file__), "data", "creditcard.csv")
    df = pd.read_csv(csv_path)
    df["Amount"] = np.log1p(df["Amount"])
    return df[["V1", "V2", "V3", "V4", "V5", "Amount"]], df["Class"]


def make_synthetic_data(n=20000, seed=42):
    rng = np.random.default_rng(seed)
    X = pd.DataFrame(
        rng.normal(size=(n, 5)), columns=["V1", "V2", "V3", "V4", "V5"]
    )
    amount = rng.lognormal(mean=3.0, sigma=1.2, size=n)
    X["Amount"] = np.log1p(amount)
    # Rare synthetic "fraud" signal: large |V1| combined with large amount.
    score = X["V1"].abs() * 0.6 + X["Amount"] * 0.4
    threshold = np.quantile(score, 0.98)  # ~2% positive rate, similar to real dataset
    y = (score > threshold).astype(int)
    return X, y


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--synthetic", action="store_true",
        help="Train on generated data instead of data/creditcard.csv"
    )
    args = parser.parse_args()

    if args.synthetic:
        print("[*] Using synthetic data (smoke-test only, not for real benchmark runs)")
        X, y = make_synthetic_data()
    else:
        print("[*] Loading data/creditcard.csv")
        X, y = load_real_data()

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )

    smote = SMOTE(random_state=42)
    X_train_balanced, y_train_balanced = smote.fit_resample(X_train, y_train)

    model = xgb.XGBClassifier(max_depth=4, learning_rate=0.1)
    model.fit(X_train_balanced, y_train_balanced)

    print(f"Original Fraud Cases: {sum(y_train == 1)}")
    print(f"New Fraud Cases (post-SMOTE): {sum(y_train_balanced == 1)}")

    y_pred = model.predict(X_test)
    print(f"Accuracy Score: {accuracy_score(y_test, y_pred):.4f}")
    print("\nConfusion Matrix")
    print(confusion_matrix(y_test, y_pred))
    print("\nClassification Report:")
    print(classification_report(y_test, y_pred))

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    joblib.dump(model, OUTPUT_PATH)
    print(f"Model saved to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
