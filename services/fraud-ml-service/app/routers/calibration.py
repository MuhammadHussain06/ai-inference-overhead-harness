import time

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool

from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


def _noop():
    """No business logic -- the whole point of this tier is to have nothing here."""
    return False, 0.0, 0.0


@router.post("/predict/calibrate", response_model=TransactionResponse, response_model_by_alias=True)
async def predict_calibrate(payload: TransactionPayload, request: Request):
    """Measures framework, dispatch and serialization overhead with zero computation
    behind it. Still goes through run_in_threadpool: the calibration arm must traverse
    every layer the AI arm does, so the difference isolates computation alone."""
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    dispatch_start = time.perf_counter()
    is_fraud, risk_score, computation_time_ms = await run_in_threadpool(_noop)
    thread_dispatch_time_ms = max(0.0, (time.perf_counter() - dispatch_start) * 1000 - computation_time_ms)

    return build_response(payload, is_fraud, risk_score, parsing_time_ms, computation_time_ms, start_total,
                          thread_dispatch_time_ms=thread_dispatch_time_ms)