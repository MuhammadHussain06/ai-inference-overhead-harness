from contextlib import asynccontextmanager

from fastapi import FastAPI

from .model import FraudModel
from .routers import mock, predict


@asynccontextmanager
async def lifespan(app: FastAPI):

    FraudModel.load()
    yield
    FraudModel.model = None


app = FastAPI(title="Fraud Detection API", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok"}


app.include_router(predict.router)
app.include_router(mock.router)
