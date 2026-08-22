import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from starlette.middleware.base import BaseHTTPMiddleware

from .model import model_registry
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
    yield
    model_registry.clear()


app = FastAPI(title="Fraud Detection API", lifespan=lifespan)
app.add_middleware(TimingMiddleware)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "loadedTiers": list(model_registry.tiers.keys()),
        "nJobsVerified": {n: tier.n_jobs_verified for n, tier in model_registry.tiers.items()},
    }


app.include_router(predict.router)
app.include_router(mock.router)
app.include_router(calibration.router)