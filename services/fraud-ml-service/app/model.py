import time

import joblib
import numpy as np
import pandas as pd
from fastapi import HTTPException

from .config import settings


class FraudML:
    def __init__(self):
        self.model = None

    def load(self):
        print(f"[fraud-ml-service] Loading model from {settings.MODEL_PATH}")
        try:
            self.model = joblib.load(settings.MODEL_PATH)
        except FileNotFoundError as e:
            raise RuntimeError(
                f"Model artifact not found at '{settings.MODEL_PATH}'. "
                f"Run training/train_model.py first (see service README)."
            ) from e
        except Exception as e:
            raise RuntimeError(f"Failed to load model into memory: {e}") from e

    def predict(self, payload):
        if self.model is None:
            raise HTTPException(status_code=500, detail="Model not initialized.")

        start_comp = time.perf_counter()
        try:
            column_names = ["V1", "V2", "V3", "V4", "V5", "Amount"]

            log_amount = np.log1p(payload.amount)
            features = [payload.v1, payload.v2, payload.v3, payload.v4, payload.v5, log_amount]
            df_input = pd.DataFrame([features], columns=column_names)

            risk_score = float(self.model.predict_proba(df_input)[0][1])
            is_fraud = bool(risk_score >= settings.FRAUD_THRESHOLD)
        except Exception as e:
            raise HTTPException(
                status_code=400, detail=f"Inference failed. Check data limits/type: {e}"
            )

        computation_time_ms = (time.perf_counter() - start_comp) * 1000
        return is_fraud, risk_score, computation_time_ms


FraudModel = FraudML()