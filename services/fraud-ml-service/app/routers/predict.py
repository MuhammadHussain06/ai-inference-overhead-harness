import time

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool

from ..model import model_registry
from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict/v{n_features:int}", response_model=TransactionResponse, response_model_by_alias=True)
async def predict(n_features: int, payload: TransactionPayload, request: Request):
    # Picks up the middleware stamp rather than starting a new clock, so framework
    # ingress stays inside the Python-side total.
    start_total = request.state.start_time

    # Covers the ASGI stack, routing, body read and Pydantic validation.
    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    tier = model_registry.get(n_features)

    dispatch_start = time.perf_counter()
    is_fraud, risk_score, comp_time_ms, df_time_ms, infer_time_ms, stall_time_ms = await run_in_threadpool(tier.predict, payload)
    # Subtracting the worker thread's own computation leaves the anyio token wait
    # and the thread handoff. Floored at 0 to absorb cross-thread timer skew.
    thread_dispatch_time_ms = max(0.0, (time.perf_counter() - dispatch_start) * 1000 - comp_time_ms)

    return build_response(
        payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
        dataframe_construction_time_ms=df_time_ms, model_inference_time_ms=infer_time_ms,
        thread_dispatch_time_ms=thread_dispatch_time_ms, compute_stall_time_ms=stall_time_ms,
    )