import time
from contextlib import asynccontextmanager

from anyio import to_thread
from fastapi import FastAPI
from starlette.middleware.base import BaseHTTPMiddleware

from .config import settings
from .model import model_registry
from .responses import calibrate_serialization_estimate
from .routers import calibration, mock, predict


class TimingMiddleware(BaseHTTPMiddleware):
    # request.state.start_time marks early event-loop entry, allowing async routes to
    # isolate thread-dispatch overhead from end-to-end Python latency metrics.
    async def dispatch(self, request, call_next):
        request.state.start_time = time.perf_counter()
        return await call_next(request)


@asynccontextmanager
async def lifespan(app: FastAPI):

    model_registry.load_all()
    calibrate_serialization_estimate()  # seed before serving traffic
    # run_in_threadpool (used by predict.py) draws on anyio's default thread
    # limiter; override its capacity here, before traffic starts, when the
    # ablation harness requests a non-default value.
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
        "loadedTiers": list(model_registry.tiers.keys()),
        "nJobsVerified": {n: tier.n_jobs_verified for n, tier in model_registry.tiers.items()},
        "threadLimiterTokens": to_thread.current_default_thread_limiter().total_tokens,
    }


app.include_router(predict.router)
app.include_router(mock.router)
app.include_router(calibration.router)