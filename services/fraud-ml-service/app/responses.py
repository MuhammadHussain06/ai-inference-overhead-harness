import time

from .schemas import PythonTelemetryDto, TransactionResponse


def build_response(payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
                   dataframe_construction_time_ms=0.0, model_inference_time_ms=0.0):
    start_serial = time.perf_counter()
    message = "Fraud detected" if is_fraud else "Transaction approved"

    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        computationTimeMs=comp_time_ms,
        dataframeConstructionTimeMs=dataframe_construction_time_ms,
        modelInferenceTimeMs=model_inference_time_ms,
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