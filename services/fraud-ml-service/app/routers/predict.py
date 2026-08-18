import time

from fastapi import APIRouter, Request

from ..model import model_registry
from ..responses import build_response
from ..schemas import TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict/v{n_features:int}", response_model=TransactionResponse, response_model_by_alias=True)
def predict(n_features: int, payload: TransactionPayload, request: Request):
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    tier = model_registry.get(n_features)
    is_fraud, risk_score, comp_time_ms, df_time_ms, infer_time_ms = tier.predict(payload)

    return build_response(
        payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
        dataframe_construction_time_ms=df_time_ms, model_inference_time_ms=infer_time_ms,
    )