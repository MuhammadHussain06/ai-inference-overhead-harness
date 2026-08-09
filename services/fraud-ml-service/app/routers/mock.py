import random
import time

from fastapi import APIRouter, Request

from ..config import settings
from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict/mock", response_model=TransactionResponse, response_model_by_alias=True)
def predict_mock(payload: TransactionPayload, request: Request):
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    comp_start = time.perf_counter()
    risk_score = round(random.uniform(0.0, 1.0), 4)
    is_fraud = risk_score >= settings.FRAUD_THRESHOLD
    computation_time_ms = (time.perf_counter() - comp_start) * 1000.0

    return build_response(payload, is_fraud, risk_score, parsing_time_ms, computation_time_ms, start_total)