class StubModel:
    """Stands in for a loaded XGBClassifier so tests need no trained artifact."""

    def __init__(self, score: float = 0.75, n_jobs: int = 1):
        self.score = score
        self.n_jobs = n_jobs
        self.last_frame = None

    def set_params(self, **params):
        for key, value in params.items():
            setattr(self, key, value)
        return self

    def predict_proba(self, frame):
        self.last_frame = frame
        return [[1.0 - self.score, self.score]]


class UnpinnableModel(StubModel):
    """Ignores set_params(n_jobs=...), reproducing a model that resists pinning."""

    def __init__(self, n_jobs: int = 8):
        super().__init__(n_jobs=n_jobs)

    def set_params(self, **params):
        params.pop("n_jobs", None)
        return super().set_params(**params)