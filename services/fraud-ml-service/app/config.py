import os


class Settings:

    APP_NAME = "Fraud Detection ML"

    FEATURE_TIERS = [int(n) for n in os.getenv("FEATURE_TIERS", "5,10,20,28").split(",")]

    MODEL_DIR = os.getenv("MODEL_DIR", "models")

    def model_path(self, n_features: int) -> str:
        return os.path.join(self.MODEL_DIR, f"fraud_model_v{n_features}.joblib")

    FRAUD_THRESHOLD = float(os.getenv("FRAUD_THRESHOLD", "0.50"))


settings = Settings()
