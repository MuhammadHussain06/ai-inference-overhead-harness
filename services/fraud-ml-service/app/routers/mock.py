import random
import time

from fastapi import APIRouter

from ..config import settings
from ..schemas import PythonTelemetryDto, TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict/mock", response_model=TransactionResponse, response_model_by_alias=True)
async def predict_mock(payload: TransactionPayload):
    start_total = time.perf_counter()

    parse_end = time.perf_counter()
    parsing_time_ms = (parse_end - start_total) * 1000.0

    comp_start = time.perf_counter()
    risk_score = round(random.uniform(0.0, 1.0), 4)

    is_fraud = risk_score >= settings.FRAUD_THRESHOLD
    computation_time_ms = (time.perf_counter() - comp_start) * 1000.0

    start_serial = time.perf_counter()
    message = "Fraud detected" if is_fraud else "Transaction approved"

    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        computationTimeMs=computation_time_ms,
        serializationResponseTimeMs=0.0,
        totalPythonExecutionTimeMs=0.0,
    )

    response = TransactionResponse(
        transactionId=payload.transactionId,
        isFraud=is_fraud,
        riskScore=risk_score,
        message=message,
        pythonTelemetry=telemetry,
    )

    end_serial = time.perf_counter()
    response.pythonTelemetry.serializationResponseTimeMs = (end_serial - start_serial) * 1000.0
    response.pythonTelemetry.totalPythonExecutionTimeMs = (time.perf_counter() - start_total) * 1000.0

    return response
