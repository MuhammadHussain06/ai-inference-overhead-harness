import os


class Settings:

    APP_NAME = "Fraud Detection ML"

 
    MODEL_PATH = os.getenv("MODEL_PATH", "models/fraud_model.joblib")


    FRAUD_THRESHOLD = float(os.getenv("FRAUD_THRESHOLD", "0.50"))


settings = Settings()
