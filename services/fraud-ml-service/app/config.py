import os


class Settings:

    FEATURE_TIERS = [int(n) for n in os.getenv("FEATURE_TIERS", "5,10,20,28").split(",")]

    MODEL_DIR = os.getenv("MODEL_DIR", "models")

    def model_path(self, n_features: int) -> str:
        return os.path.join(self.MODEL_DIR, f"fraud_model_v{n_features}.joblib")

    FRAUD_THRESHOLD = float(os.getenv("FRAUD_THRESHOLD", "0.50"))

    # Ablation-only knob. Unset leaves anyio's own default thread-limiter capacity
    # in place, so the main suite measures the stock configuration.
    _thread_limiter_env = os.getenv("THREAD_LIMITER_TOKENS", "").strip()
    THREAD_LIMITER_TOKENS = int(_thread_limiter_env) if _thread_limiter_env else None

    # Reported on /health so the harness verifies single-threaded numeric libraries
    # each rep. n_jobs alone does not constrain the BLAS/OpenMP layer beneath it.
    NUMERIC_THREAD_ENV_VARS = (
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
    )

    def numeric_thread_env(self) -> dict:
        return {var: os.getenv(var) for var in self.NUMERIC_THREAD_ENV_VARS}


settings = Settings()