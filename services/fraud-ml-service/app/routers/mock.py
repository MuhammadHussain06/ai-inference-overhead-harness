import random
import time

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool

from ..config import settings
from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


def _score_mock():
    # computationTimeMs stays 0.0, matching calibration._noop(): the field means
    # dataframeConstructionTimeMs + modelInferenceTimeMs, neither of which applies here.
    risk_score = random.uniform(0.0, 1.0)
    is_fraud = risk_score >= settings.FRAUD_THRESHOLD
    return is_fraud, risk_score, 0.0


@router.post("/predict/mock", response_model=TransactionResponse, response_model_by_alias=True)
async def predict_mock(payload: TransactionPayload, request: Request):
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    dispatch_start = time.perf_counter()
    is_fraud, risk_score, computation_time_ms = await run_in_threadpool(_score_mock)
    thread_dispatch_time_ms = max(0.0, (time.perf_counter() - dispatch_start) * 1000 - computation_time_ms)

    return build_response(payload, is_fraud, risk_score, parsing_time_ms, computation_time_ms, start_total,
                          thread_dispatch_time_ms=thread_dispatch_time_ms)