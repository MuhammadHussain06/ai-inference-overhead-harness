import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from starlette.middleware.base import BaseHTTPMiddleware

from .model import FraudModel
from .routers import mock, predict


class TimingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        request.state.start_time = time.perf_counter()
        return await call_next(request)


@asynccontextmanager
async def lifespan(app: FastAPI):

    FraudModel.load()
    yield
    FraudModel.model = None


app = FastAPI(title="Fraud Detection API", lifespan=lifespan)
app.add_middleware(TimingMiddleware)


@app.get("/health")
def health():
    return {"status": "ok"}


app.include_router(predict.router)
app.include_router(mock.router)