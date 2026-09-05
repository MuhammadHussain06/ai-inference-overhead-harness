import os


class Settings:

    APP_NAME = "Fraud Detection ML"

    FEATURE_TIERS = [int(n) for n in os.getenv("FEATURE_TIERS", "5,10,20,28").split(",")]

    MODEL_DIR = os.getenv("MODEL_DIR", "models")

    def model_path(self, n_features: int) -> str:
        return os.path.join(self.MODEL_DIR, f"fraud_model_v{n_features}.joblib")

    FRAUD_THRESHOLD = float(os.getenv("FRAUD_THRESHOLD", "0.50"))

    # Overrides anyio's default thread-limiter capacity (40) used by run_in_threadpool.
    # Unset (default) leaves anyio's own default in place. Ablation-only knob (see
    # run-ablation.sh); the main suite never sets this.
    _thread_limiter_env = os.getenv("THREAD_LIMITER_TOKENS", "").strip()
    THREAD_LIMITER_TOKENS = int(_thread_limiter_env) if _thread_limiter_env else None


settings = Settings()