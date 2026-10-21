# One loaded XGBoost model per tier, its timed predict path, and the tier registry.
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
        # Matches the training schema exactly; XGBoost validates feature names at predict time.
        self.column_names = [f"V{i}" for i in range(1, n_features + 1)] + ["Amount"]
        self.n_jobs_verified = False
        # Tri-state: None until this tier serves a request, so the harness can tell
        # "not yet exercised" from "exercised and unpinned".
        self.n_jobs_runtime_verified = None

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

        # Reads the value back rather than trusting set_params to have applied it.
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

        # Paired clocks: perf_counter gives elapsed time, thread_time gives CPU time
        # on this worker thread only. Their difference is off-CPU time.
        start_comp = time.perf_counter()
        cpu_start = time.thread_time()
        try:
            if len(payload.features) < self.n_features:
                # Client error: raised as HTTPException so it passes through as 400,
                # while the generic handler below reports every other failure
                # (including a ValueError from predict_proba) as 500.
                raise HTTPException(
                    status_code=400,
                    detail=f"Expected at least {self.n_features} feature values, got {len(payload.features)}"
                )

            # log1p matches the transform train_model.py applies to Amount.
            log_amount = np.log1p(payload.amount)
            row = list(payload.features[: self.n_features]) + [log_amount]

            start_df = time.perf_counter()
            df_input = pd.DataFrame([row], columns=self.column_names)
            dataframe_construction_time_ms = (time.perf_counter() - start_df) * 1000

            # Model inference: the whole predict_proba call, i.e. XGBoost's per-call conversion
            # of the DataFrame (in-place prediction path, no DMatrix), feature-name validation
            # and tree traversal. Conversion dominates (table 9, run-predict-composition.sh).
            start_infer = time.perf_counter()
            risk_score = float(self.model.predict_proba(df_input)[0][1])
            model_inference_time_ms = (time.perf_counter() - start_infer) * 1000

            is_fraud = bool(risk_score >= settings.FRAUD_THRESHOLD)
        except HTTPException:
            raise
        except Exception as e:
            # Server-side computation fault, including a ValueError from predict_proba.
            raise HTTPException(status_code=500, detail=f"Inference failed: {e}")

        computation_time_ms = (time.perf_counter() - start_comp) * 1000
        cpu_time_ms = (time.thread_time() - cpu_start) * 1000
        # Compute stall: off-CPU time within the computation window (GIL wait, OS
        # preemption), a subset of computation_time_ms. Floored at 0 because the two
        # clocks are read a line apart and can disagree by a rounding step.
        compute_stall_time_ms = max(0.0, computation_time_ms - cpu_time_ms)

        # Runs after every timing window has closed, once per tier per process, to catch
        # a library that resets n_jobs when the booster is first exercised.
        if self.n_jobs_runtime_verified is None:
            self.n_jobs_runtime_verified = (getattr(self.model, "n_jobs", None) == 1)
            if not self.n_jobs_runtime_verified:
                print(f"[fraud-ml-service] WARNING: v{self.n_features} model reports "
                      f"n_jobs={getattr(self.model, 'n_jobs', None)} after first inference, expected 1.")

        return (is_fraud, risk_score, computation_time_ms, dataframe_construction_time_ms,
                model_inference_time_ms, compute_stall_time_ms)


class FraudModelRegistry:

    def __init__(self):
        self.tiers = {}

    def load_all(self):
        for n in settings.FEATURE_TIERS:
            tier = FraudMLTier(n)
            # Assigned only after load() returns, so a partially loaded tier is never registered.
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