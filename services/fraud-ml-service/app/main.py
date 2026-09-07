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
    # Stamps the earliest point the ASGI stack exposes, so totalPythonExecutionTimeMs
    # covers framework ingress (routing, body read, validation) rather than starting
    # at the route handler. Must stay the outermost user middleware.
    async def dispatch(self, request, call_next):
        request.state.start_time = time.perf_counter()
        return await call_next(request)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Everything here runs before the first request is served: model loading and
    # estimator seeding must not land inside a measured request, and the thread
    # limiter must hold one value for the whole process lifetime.
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
        # Uvicorn runs several worker processes; this response describes whichever
        # one answered. workerPid lets the harness tell them apart across polls.
        "workerPid": os.getpid(),
        "loadedTiers": list(model_registry.tiers.keys()),
        "nJobsVerified": {n: tier.n_jobs_verified for n, tier in model_registry.tiers.items()},
        # null until a tier has served its first request; the harness checks it
        # after warm-up, when every tier has run.
        "nJobsRuntimeVerified": {n: tier.n_jobs_runtime_verified for n, tier in model_registry.tiers.items()},
        "numericThreadEnv": settings.numeric_thread_env(),
        "threadLimiterTokens": to_thread.current_default_thread_limiter().total_tokens,
        "serializationEstimateMs": get_serialization_estimate(),
    }


app.include_router(predict.router)
app.include_router(mock.router)
app.include_router(calibration.router)