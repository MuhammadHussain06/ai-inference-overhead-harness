"""Guards the EWMA serialization estimator and the totals built on it."""

import json
import time

import pytest

from app import responses
from app.responses import (
    build_response,
    calibrate_serialization_estimate,
    get_serialization_estimate,
)

TELEMETRY_FIELDS = {
    "parsingRequestTimeMs",
    "threadDispatchTimeMs",
    "computationTimeMs",
    "dataframeConstructionTimeMs",
    "modelInferenceTimeMs",
    "computeStallMs",
    "serializationResponseTimeMs",
    "totalPythonExecutionTimeMs",
}


def _emit(payload, **kwargs):
    defaults = dict(
        is_fraud=False,
        risk_score=0.25,
        parsing_time_ms=0.2,
        comp_time_ms=1.5,
        start_total=time.perf_counter(),
    )
    defaults.update(kwargs)
    response = build_response(payload, **defaults)
    return json.loads(response.body)


def test_calibration_produces_a_positive_estimate():
    estimate = calibrate_serialization_estimate(n_warmup=20)
    assert estimate > 0.0
    assert get_serialization_estimate() == pytest.approx(estimate)


def test_calibration_is_sub_millisecond():
    """A serialization estimate near the inference times it offsets would invalidate the decomposition."""
    assert calibrate_serialization_estimate(n_warmup=20) < 1.0


def test_get_estimate_is_zero_before_calibration():
    assert get_serialization_estimate() == 0.0


def test_build_response_self_calibrates_when_startup_seeding_was_skipped(payload):
    assert responses._serialization_estimate_ms is None
    _emit(payload)
    assert responses._serialization_estimate_ms > 0.0


def test_response_carries_every_telemetry_field(payload):
    body = _emit(payload)
    assert set(body["pythonTelemetry"]) == TELEMETRY_FIELDS


def test_response_echoes_identity_and_verdict(payload):
    body = _emit(payload, is_fraud=True, risk_score=0.91)
    assert body["transactionId"] == payload.transactionId
    assert body["isFraud"] is True
    assert body["riskScore"] == pytest.approx(0.91)


def test_total_exceeds_the_serialization_estimate_it_embeds(payload):
    calibrate_serialization_estimate(n_warmup=20)
    estimate = get_serialization_estimate()
    body = _emit(payload)
    assert body["pythonTelemetry"]["totalPythonExecutionTimeMs"] > estimate


def test_total_covers_elapsed_wall_time(payload):
    calibrate_serialization_estimate(n_warmup=20)
    start = time.perf_counter()
    time.sleep(0.01)
    body = _emit(payload, start_total=start)
    assert body["pythonTelemetry"]["totalPythonExecutionTimeMs"] >= 10.0


def test_reported_estimate_is_the_one_used_for_the_total(payload):
    calibrate_serialization_estimate(n_warmup=20)
    before = get_serialization_estimate()
    body = _emit(payload)
    assert body["pythonTelemetry"]["serializationResponseTimeMs"] == pytest.approx(before)


def test_estimate_converges_down_from_an_inflated_seed(payload):
    responses._serialization_estimate_ms = 100.0
    for _ in range(100):
        _emit(payload)
    converged = get_serialization_estimate()
    assert 0.0 < converged < 1.0


def test_estimate_decreases_monotonically_while_above_true_cost(payload):
    responses._serialization_estimate_ms = 100.0
    previous = 100.0
    for _ in range(10):
        _emit(payload)
        current = get_serialization_estimate()
        assert current < previous
        previous = current


def test_estimate_stays_positive_and_bounded_under_sustained_load(payload):
    calibrate_serialization_estimate(n_warmup=20)
    for _ in range(500):
        _emit(payload)
    assert 0.0 < get_serialization_estimate() < 1.0