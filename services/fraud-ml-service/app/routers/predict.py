import time

from fastapi import APIRouter, Request

from ..model import FraudModel
from ..schemas import PythonTelemetryDto, TransactionPayload, TransactionResponse

router = APIRouter()


@router.post("/predict", response_model=TransactionResponse, response_model_by_alias=True)
def predict(payload: TransactionPayload, request: Request):
    start_total = request.state.start_time

    parsing_time_ms = (time.perf_counter() - start_total) * 1000

    is_fraud, risk_score, comp_time_ms = FraudModel.predict(payload)

    start_serial = time.perf_counter()
    message = "Fraud detected" if is_fraud else "Transaction approved"

    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        computationTimeMs=comp_time_ms,
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
    response.pythonTelemetry.serializationResponseTimeMs = (end_serial - start_serial) * 1000
    response.pythonTelemetry.totalPythonExecutionTimeMs = (time.perf_counter() - start_total) * 1000

    return response