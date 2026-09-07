"""Guards the Python-side timing instruments the paper reports on."""

import math

import pytest
from fastapi import HTTPException

from app.model import FraudMLTier, FraudModelRegistry
from app.schemas import TransactionPayload

from stubs import StubModel, UnpinnableModel


def test_column_names_match_tier():
    assert FraudMLTier(5).column_names == ["V1", "V2", "V3", "V4", "V5", "Amount"]
    assert FraudMLTier(28).column_names[-1] == "Amount"
    assert len(FraudMLTier(28).column_names) == 29


def test_all_returned_timings_are_nonnegative(tier, payload):
    _, _, comp_ms, df_ms, infer_ms, stall_ms = tier.predict(payload)
    assert min(comp_ms, df_ms, infer_ms, stall_ms) >= 0.0


def test_computation_time_covers_its_components(tier, payload):
    _, _, comp_ms, df_ms, infer_ms, _ = tier.predict(payload)
    assert comp_ms >= df_ms + infer_ms


def test_compute_stall_never_exceeds_computation_time(tier, payload):
    """stall = wall - cpu, so it is bounded by wall time even under contention."""
    _, _, comp_ms, _, _, stall_ms = tier.predict(payload)
    assert 0.0 <= stall_ms <= comp_ms


def test_risk_score_and_threshold_agree(tier, payload):
    tier.model = StubModel(score=0.75)
    is_fraud, risk_score, *_ = tier.predict(payload)
    assert risk_score == pytest.approx(0.75)
    assert is_fraud is True

    tier.model = StubModel(score=0.10)
    is_fraud, risk_score, *_ = tier.predict(payload)
    assert risk_score == pytest.approx(0.10)
    assert is_fraud is False


def test_rejects_payload_with_too_few_features(tier):
    short = TransactionPayload(
        transactionId="11111111-2222-3333-4444-555555555555",
        amount=100.0,
        features=[0.5] * 4,
    )
    with pytest.raises(HTTPException) as exc:
        tier.predict(short)
    assert exc.value.status_code == 400


def test_frame_is_sliced_to_tier_width_with_log_amount(tier, payload):
    tier.predict(payload)
    frame = tier.model.last_frame
    assert list(frame.columns) == tier.column_names
    assert frame.shape == (1, 6)
    assert frame["Amount"].iloc[0] == pytest.approx(math.log1p(100.0))


def test_extra_features_beyond_tier_are_ignored(tier):
    marked = TransactionPayload(
        transactionId="11111111-2222-3333-4444-555555555555",
        amount=100.0,
        features=[0.5] * 5 + [999.0] * 23,
    )
    tier.predict(marked)
    assert 999.0 not in tier.model.last_frame.iloc[0].values


def test_unloaded_tier_raises_500(payload):
    with pytest.raises(HTTPException) as exc:
        FraudMLTier(5).predict(payload)
    assert exc.value.status_code == 500
    # Detail intact, so the `except HTTPException: raise` clause has not been
    # replaced by the generic handler below it.
    assert "Model not initialized" in exc.value.detail


def test_runtime_n_jobs_is_verified_on_first_predict(tier, payload):
    assert tier.n_jobs_runtime_verified is None
    tier.predict(payload)
    assert tier.n_jobs_runtime_verified is True


def test_runtime_n_jobs_flags_an_unpinned_model(tier, payload):
    tier.model = UnpinnableModel(n_jobs=8)
    tier.predict(payload)
    assert tier.n_jobs_runtime_verified is False


def test_load_time_verification_flags_an_unpinned_model(monkeypatch):
    unpinned = FraudMLTier(5)
    monkeypatch.setattr("app.model.joblib.load", lambda _: UnpinnableModel(n_jobs=8))
    unpinned.load()
    assert unpinned.n_jobs_verified is False


def test_load_time_verification_passes_for_a_pinnable_model(monkeypatch):
    pinnable = FraudMLTier(5)
    monkeypatch.setattr("app.model.joblib.load", lambda _: StubModel(n_jobs=8))
    pinnable.load()
    assert pinnable.n_jobs_verified is True
    assert pinnable.model.n_jobs == 1


def test_missing_artifact_names_the_training_command(monkeypatch):
    def raise_missing(_):
        raise FileNotFoundError

    monkeypatch.setattr("app.model.joblib.load", raise_missing)
    with pytest.raises(RuntimeError, match="train_model.py"):
        FraudMLTier(5).load()


def test_registry_rejects_an_unconfigured_tier():
    with pytest.raises(HTTPException) as exc:
        FraudModelRegistry().get(99)
    assert exc.value.status_code == 404