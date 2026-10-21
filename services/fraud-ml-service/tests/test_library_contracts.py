"""Library contracts: third-party behavior the measurement design depends on, pinned so that
a dependency upgrade which changes it fails here instead of silently invalidating a claim."""

import threading
import time
from pathlib import Path

import anyio
import numpy as np
import pandas as pd
import pytest
from anyio import to_thread
from fastapi.testclient import TestClient
from starlette.middleware.errors import ServerErrorMiddleware
from starlette.middleware.exceptions import ExceptionMiddleware
from xgboost import core as xgb_core
from xgboost import data as xgb_data
from xgboost import sklearn as xgb_sklearn

from app.config import settings
from app.main import TimingMiddleware, app
from app.model import FraudMLTier

MODELS_DIR = Path(__file__).resolve().parents[1] / "models"
TIERS = [5, 10, 20, 28]


def _load_tier(n_features, monkeypatch):
    monkeypatch.setattr(settings, "MODEL_DIR", str(MODELS_DIR))
    tier = FraudMLTier(n_features)
    tier.load()
    return tier


def _capture_frames(tier, monkeypatch):
    frames = []
    original = tier.model.predict_proba

    def capturing(frame, *args, **kwargs):
        frames.append(frame)
        return original(frame, *args, **kwargs)

    monkeypatch.setattr(tier.model, "predict_proba", capturing)
    return frames


# XGBoost: model inference is the in-place prediction path, with per-call pandas conversion.

def test_predict_proba_on_the_request_frame_uses_inplace_predict_and_never_builds_a_dmatrix(
        monkeypatch, payload):
    """The sklearn wrapper falls back to DMatrix(X) whenever inplace_predict is unavailable
    or raises TypeError; that fallback would change what modelInferenceTimeMs measures."""
    tier = _load_tier(5, monkeypatch)
    expected_score = tier.predict(payload)[1]

    inplace_calls = []
    original_inplace = xgb_core.Booster.inplace_predict

    def spy_inplace(self, *args, **kwargs):
        inplace_calls.append(kwargs)
        return original_inplace(self, *args, **kwargs)

    def refuse_dmatrix(*args, **kwargs):
        raise AssertionError("DMatrix constructed on the predict path")

    monkeypatch.setattr(xgb_core.Booster, "inplace_predict", spy_inplace)
    # The name the sklearn fallback resolves, and the constructor itself.
    monkeypatch.setattr(xgb_sklearn, "DMatrix", refuse_dmatrix)
    monkeypatch.setattr(xgb_core.DMatrix, "__init__", refuse_dmatrix)

    _, score, *_ = tier.predict(payload)

    assert len(inplace_calls) == 1
    assert inplace_calls[0]["validate_features"] is True
    assert score == expected_score


def test_predict_proba_converts_the_dataframe_on_every_call(monkeypatch, payload):
    """No conversion is cached across calls, so every request pays it inside model inference."""
    tier = _load_tier(5, monkeypatch)
    conversions = []
    original_transform = xgb_data._transform_pandas_df

    def spy_transform(*args, **kwargs):
        conversions.append(args[0].shape)
        return original_transform(*args, **kwargs)

    monkeypatch.setattr(xgb_data, "_transform_pandas_df", spy_transform)

    tier.predict(payload)
    tier.predict(payload)

    assert conversions == [(1, 6), (1, 6)]


def test_xgboost_rejects_a_frame_whose_column_names_differ_from_training(monkeypatch):
    """Feature-name validation is active, so the service's column names must match exactly."""
    tier = _load_tier(5, monkeypatch)
    wrong = pd.DataFrame([[0.5] * 6], columns=[f"f{i}" for i in range(6)])

    with pytest.raises(ValueError, match="feature_names mismatch"):
        tier.model.predict_proba(wrong)


# pandas: the request frame matches the model schema and has a fixed dtype.

@pytest.mark.parametrize("n_features", TIERS)
def test_request_frame_is_one_float64_row_named_as_the_model_features(monkeypatch, payload, n_features):
    """Conversion cost depends on dtype, so a change from float64 would shift model inference."""
    tier = _load_tier(n_features, monkeypatch)
    frames = _capture_frames(tier, monkeypatch)

    tier.predict(payload)

    frame = frames[0]
    booster = tier.model.get_booster()
    assert frame.shape == (1, n_features + 1)
    assert all(dtype == np.float64 for dtype in frame.dtypes)
    assert list(frame.columns) == list(tier.model.feature_names_in_) == booster.feature_names
    assert set(booster.feature_types) == {"float"}


# Starlette: P0 is stamped by the outermost user middleware.

def test_p0_middleware_is_wrapped_directly_by_server_error_middleware_and_wraps_exception_middleware():
    """Anything between ServerErrorMiddleware and TimingMiddleware would run before P0 and
    move from the Python total into the estimated bridge overhead."""
    TestClient(app).get("/health")

    chain = []
    node = app.middleware_stack
    while node is not app.router:
        chain.append(type(node))
        node = node.app

    assert chain == [ServerErrorMiddleware, TimingMiddleware, ExceptionMiddleware]


# anyio: THREAD_LIMITER_TOKENS reaches the limiter that thread dispatch waits on.

def test_anyio_default_thread_limiter_has_40_tokens():
    """Compose sets THREAD_LIMITER_TOKENS=40 as anyio's own default outside the ablation."""
    async def read_default():
        return to_thread.current_default_thread_limiter().total_tokens

    assert anyio.run(read_default) == 40


def test_configured_thread_limiter_tokens_govern_the_thread_hand_off(monkeypatch):
    """run_in_threadpool passes no limiter, so the hand-off holds the event loop's default
    limiter, which lifespan resizes to THREAD_LIMITER_TOKENS."""
    monkeypatch.setattr(settings, "MODEL_DIR", str(MODELS_DIR))
    monkeypatch.setattr(settings, "THREAD_LIMITER_TOKENS", 7)

    hand_offs = []
    original_run_sync = to_thread.run_sync

    async def spy_run_sync(func, *args, **kwargs):
        default = to_thread.current_default_thread_limiter()

        def observed(*inner_args):
            hand_offs.append((kwargs.get("limiter"), default.total_tokens, default.borrowed_tokens))
            return func(*inner_args)

        return await original_run_sync(observed, *args, **kwargs)

    monkeypatch.setattr(to_thread, "run_sync", spy_run_sync)

    with TestClient(app) as client:
        assert client.post("/predict/calibrate", json={
            "transactionId": "11111111-2222-3333-4444-555555555555",
            "amount": 100.0,
            "features": [0.5] * 28,
        }).status_code == 200
        assert client.get("/health").json()["threadLimiterTokens"] == 7

    assert hand_offs == [(None, 7, 1)]


# time.thread_time: CPU time of the calling thread only, so wall minus CPU is off-CPU time.

def _run_in_worker(action):
    """Runs action on a fresh thread and returns its (wall, thread CPU) deltas in seconds."""
    result = {}

    def target():
        wall_start, cpu_start = time.perf_counter(), time.thread_time()
        action()
        result["deltas"] = (time.perf_counter() - wall_start, time.thread_time() - cpu_start)

    worker = threading.Thread(target=target)
    worker.start()
    worker.join()
    return result["deltas"]


def test_thread_time_does_not_advance_while_the_worker_sleeps():
    wall, cpu = _run_in_worker(lambda: time.sleep(0.05))

    assert wall >= 0.05
    assert cpu < 0.2 * wall


def test_thread_time_excludes_other_threads_cpu_while_the_worker_blocks():
    """A worker blocked while another thread runs (as under GIL contention) accrues
    wall time but not its own CPU time: the premise of the compute stall."""
    blocked = threading.Event()
    released = threading.Event()

    def spin_other_thread():
        blocked.wait(timeout=2.0)
        deadline = time.perf_counter() + 0.05
        while time.perf_counter() < deadline:
            pass
        released.set()

    def block():
        blocked.set()
        released.wait(timeout=2.0)

    spinner = threading.Thread(target=spin_other_thread)
    spinner.start()
    wall, cpu = _run_in_worker(block)
    spinner.join()

    assert wall >= 0.05
    assert cpu < 0.2 * wall


def test_thread_time_advances_while_the_worker_computes():
    target_cpu = 0.02

    def busy():
        start = time.thread_time()
        deadline = time.perf_counter() + 2.0
        while time.thread_time() - start < target_cpu and time.perf_counter() < deadline:
            pass

    wall, cpu = _run_in_worker(busy)

    assert cpu >= target_cpu
