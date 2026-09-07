"""Endpoint-level guards, including the telemetry symmetry the three-strategy design rests on."""

import os

import pytest
from fastapi.testclient import TestClient

from app.main import TimingMiddleware, app
from app.model import FraudMLTier, model_registry

from stubs import StubModel

AI_ENDPOINT = "/predict/v5"
MOCK_ENDPOINT = "/predict/mock"
CALIBRATION_ENDPOINT = "/predict/calibrate"
ALL_ENDPOINTS = [AI_ENDPOINT, MOCK_ENDPOINT, CALIBRATION_ENDPOINT]

BODY = {
    "transactionId": "11111111-2222-3333-4444-555555555555",
    "amount": 100.0,
    "features": [0.5] * 28,
}


@pytest.fixture
def client(monkeypatch):
    tier = FraudMLTier(5)
    tier.model = StubModel()
    tier.n_jobs_verified = True
    monkeypatch.setitem(model_registry.tiers, 5, tier)
    return TestClient(app)


def _telemetry(client, endpoint, body=None):
    response = client.post(endpoint, json=body or BODY)
    assert response.status_code == 200
    return response.json()["pythonTelemetry"]


def test_timing_middleware_is_the_outermost_user_middleware():
    """A middleware added after this one would run before the stamp, and its cost
    would leave totalPythonExecutionTimeMs for estimatedNetworkOverheadMs instead."""
    assert app.user_middleware[0].cls is TimingMiddleware


def test_health_reports_loaded_tiers_and_pinning(client):
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert body["loadedTiers"] == [5]
    assert body["nJobsVerified"] == {"5": True}


def test_health_identifies_the_answering_worker(client):
    """Uvicorn runs several workers; the harness polls until it has seen each one."""
    assert client.get("/health").json()["workerPid"] == os.getpid()


def test_health_reports_numeric_thread_env(client, monkeypatch):
    monkeypatch.setenv("OMP_NUM_THREADS", "1")
    env = client.get("/health").json()["numericThreadEnv"]
    assert env["OMP_NUM_THREADS"] == "1"
    assert set(env) == {
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
    }


def test_health_reports_runtime_pinning_after_first_inference(client):
    assert client.get("/health").json()["nJobsRuntimeVerified"] == {"5": None}
    client.post(AI_ENDPOINT, json=BODY)
    assert client.get("/health").json()["nJobsRuntimeVerified"] == {"5": True}


@pytest.mark.parametrize("endpoint", ALL_ENDPOINTS)
def test_every_strategy_emits_the_same_telemetry_fields(client, endpoint):
    """Decomposition by subtraction is only valid if the arms report identically."""
    assert set(_telemetry(client, endpoint)) == set(_telemetry(client, AI_ENDPOINT))


@pytest.mark.parametrize("endpoint", ALL_ENDPOINTS)
def test_no_strategy_reports_a_negative_timing(client, endpoint):
    assert all(value >= 0.0 for value in _telemetry(client, endpoint).values())


@pytest.mark.parametrize("endpoint", [MOCK_ENDPOINT, CALIBRATION_ENDPOINT])
def test_baseline_arms_report_zero_computation(client, endpoint):
    """Both baselines must sit at the zero-work floor to bound AI inference cost."""
    telemetry = _telemetry(client, endpoint)
    assert telemetry["computationTimeMs"] == 0.0
    assert telemetry["dataframeConstructionTimeMs"] == 0.0
    assert telemetry["modelInferenceTimeMs"] == 0.0
    assert telemetry["computeStallMs"] == 0.0


def test_ai_arm_reports_real_compute(client):
    telemetry = _telemetry(client, AI_ENDPOINT)
    assert telemetry["computationTimeMs"] > 0.0
    assert telemetry["modelInferenceTimeMs"] > 0.0
    assert telemetry["dataframeConstructionTimeMs"] > 0.0


@pytest.mark.parametrize("endpoint", ALL_ENDPOINTS)
def test_total_is_the_largest_reported_timing(client, endpoint):
    telemetry = _telemetry(client, endpoint)
    total = telemetry.pop("totalPythonExecutionTimeMs")
    assert total >= max(telemetry.values())


def test_mock_score_stays_in_range(client):
    scores = {client.post(MOCK_ENDPOINT, json=BODY).json()["riskScore"] for _ in range(20)}
    assert all(0.0 <= score <= 1.0 for score in scores)
    assert len(scores) > 1, "mock scoring should vary per request"


def test_calibration_score_is_the_fixed_floor(client):
    body = client.post(CALIBRATION_ENDPOINT, json=BODY).json()
    assert body["riskScore"] == 0.0
    assert body["isFraud"] is False


def test_unconfigured_tier_returns_404(client):
    assert client.post("/predict/v99", json=BODY).status_code == 404


def test_too_few_features_returns_400(client):
    short = dict(BODY, features=[0.5] * 4)
    assert client.post(AI_ENDPOINT, json=short).status_code == 400


def test_malformed_payload_returns_422(client):
    assert client.post(AI_ENDPOINT, json={"amount": 100.0}).status_code == 422