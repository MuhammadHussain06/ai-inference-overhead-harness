import time

from fastapi import APIRouter, Request

from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict/calibrate", response_model=TransactionResponse, response_model_by_alias=True)
def predict_calibrate(payload: TransactionPayload, request: Request):
    """No business logic -- isolates instrumentation/serialization overhead as a floor."""
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000
    computation_time_ms = 0.0
    is_fraud = False
    risk_score = 0.0

    return build_response(payload, is_fraud, risk_score, parsing_time_ms, computation_time_ms, start_total)