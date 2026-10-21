# FastAPI app: timing middleware (P0), per-process startup, /health and the three arm routers.
import os
import time
from contextlib import asynccontextmanager

from anyio import to_thread
from fastapi import FastAPI
from starlette.middleware.base import BaseHTTPMiddleware

from .config import settings
from .model import model_registry
from .responses import calibrate_serialization_estimate, get_serialization_estimate
from .routers import calibration, mock, predict


class TimingMiddleware(BaseHTTPMiddleware):
    # P0: the earliest point user code sees a request, so parsingRequestTimeMs and the
    # Python total include routing, body read and validation. uvicorn's HTTP parsing and
    # any event-loop wait before this stamp fall into the estimated bridge overhead.
    # Must stay the outermost user middleware.
    async def dispatch(self, request, call_next):
        request.state.start_time = time.perf_counter()
        return await call_next(request)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Runs once per worker process before it serves traffic, so model loading and
    # estimator seeding never land inside a measured request. Each process sets its own
    # thread limiter, so total token capacity scales with the worker count.
    model_registry.load_all()
    calibrate_serialization_estimate()
    if settings.THREAD_LIMITER_TOKENS is not None:
        to_thread.current_default_thread_limiter().total_tokens = settings.THREAD_LIMITER_TOKENS
    yield
    model_registry.clear()


app = FastAPI(title="Fraud Detection API", lifespan=lifespan)
app.add_middleware(TimingMiddleware)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        # Describes only the worker process that answered; workerPid tells them apart
        # across polls.
        "workerPid": os.getpid(),
        "loadedTiers": list(model_registry.tiers.keys()),
        "nJobsVerified": {n: tier.n_jobs_verified for n, tier in model_registry.tiers.items()},
        # null until a tier has served its first request; the harness checks it after
        # warm-up, when every tier has run.
        "nJobsRuntimeVerified": {n: tier.n_jobs_runtime_verified for n, tier in model_registry.tiers.items()},
        "numericThreadEnv": settings.numeric_thread_env(),
        "threadLimiterTokens": to_thread.current_default_thread_limiter().total_tokens,
        "serializationEstimateMs": get_serialization_estimate(),
    }


app.include_router(predict.router)
app.include_router(mock.router)
app.include_router(calibration.router)