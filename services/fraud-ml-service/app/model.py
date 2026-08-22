import time

import joblib
import numpy as np
import pandas as pd
from fastapi import HTTPException

from .config import settings


class FraudMLTier:


    def __init__(self, n_features: int):
        self.n_features = n_features
        self.model = None
        self.column_names = [f"V{i}" for i in range(1, n_features + 1)] + ["Amount"]
        self.n_jobs_verified = False

    def load(self):
        path = settings.model_path(self.n_features)
        print(f"[fraud-ml-service] Loading v{self.n_features} model from {path}")
        try:
            self.model = joblib.load(path)
        except FileNotFoundError as e:
            raise RuntimeError(
                f"Model artifact not found at '{path}'. Run "
                f"training/train_model.py --n-features {self.n_features} first."
            ) from e
        except Exception as e:
            raise RuntimeError(f"Failed to load v{self.n_features} model: {e}") from e

        try:
            self.model.set_params(n_jobs=1)
        except Exception as e:
            print(f"[fraud-ml-service] Warning: could not pin n_jobs=1 on v{self.n_features} model: {e}")

        actual_n_jobs = getattr(self.model, "n_jobs", None)
        self.n_jobs_verified = (actual_n_jobs == 1)
        if self.n_jobs_verified:
            print(f"[fraud-ml-service] Verified v{self.n_features} model n_jobs={actual_n_jobs}.")
        else:
            print(f"[fraud-ml-service] WARNING: v{self.n_features} model reports n_jobs={actual_n_jobs} "
                  f"after pinning attempt, expected 1. Inference may not be single-threaded.")

    def predict(self, payload):
        if self.model is None:
            raise HTTPException(status_code=500, detail="Model not initialized.")

        start_comp = time.perf_counter()
        cpu_start = time.thread_time()
        try:
            if len(payload.features) < self.n_features:
                raise ValueError(
                    f"Expected at least {self.n_features} feature values, got {len(payload.features)}"
                )

            log_amount = np.log1p(payload.amount)
            row = list(payload.features[: self.n_features]) + [log_amount]

            start_df = time.perf_counter()
            df_input = pd.DataFrame([row], columns=self.column_names)
            dataframe_construction_time_ms = (time.perf_counter() - start_df) * 1000

            start_infer = time.perf_counter()
            risk_score = float(self.model.predict_proba(df_input)[0][1])
            model_inference_time_ms = (time.perf_counter() - start_infer) * 1000

            is_fraud = bool(risk_score >= settings.FRAUD_THRESHOLD)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=f"Invalid request: {e}")
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Inference failed: {e}")  # server fault, not client error

        computation_time_ms = (time.perf_counter() - start_comp) * 1000
        # Off-CPU time during computation (GIL contention / OS scheduling), floored at 0.
        cpu_time_ms = (time.thread_time() - cpu_start) * 1000
        compute_stall_time_ms = max(0.0, computation_time_ms - cpu_time_ms)

        return (is_fraud, risk_score, computation_time_ms, dataframe_construction_time_ms,
                model_inference_time_ms, compute_stall_time_ms)


class FraudModelRegistry:

    def __init__(self):
        self.tiers = {}

    def load_all(self):
        for n in settings.FEATURE_TIERS:
            tier = FraudMLTier(n)
            tier.load()
            self.tiers[n] = tier

    def get(self, n_features: int) -> FraudMLTier:
        if n_features not in self.tiers:
            raise HTTPException(
                status_code=404,
                detail=f"No model loaded for tier v{n_features}. Configured tiers: {list(self.tiers)}",
            )
        return self.tiers[n_features]

    def clear(self):
        self.tiers = {}


model_registry = FraudModelRegistry()