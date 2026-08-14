import time

from fastapi import Response

from .schemas import PythonTelemetryDto, TransactionResponse


def build_response(payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
                   dataframe_construction_time_ms=0.0, model_inference_time_ms=0.0):
    message = "Fraud detected" if is_fraud else "Transaction approved"

    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        computationTimeMs=comp_time_ms,
        dataframeConstructionTimeMs=dataframe_construction_time_ms,
        modelInferenceTimeMs=model_inference_time_ms,
        serializationResponseTimeMs=0.0,
        totalPythonExecutionTimeMs=0.0,
    )

    response_model = TransactionResponse(
        transactionId=payload.transactionId,
        isFraud=is_fraud,
        riskScore=risk_score,
        message=message,
        pythonTelemetry=telemetry,
    )

    start_serial = time.perf_counter()
    body_bytes = response_model.model_dump_json(by_alias=True).encode("utf-8")
    serialization_time_ms = (time.perf_counter() - start_serial) * 1000

    response_model.pythonTelemetry.serializationResponseTimeMs = serialization_time_ms
    response_model.pythonTelemetry.totalPythonExecutionTimeMs = (time.perf_counter() - start_total) * 1000
    final_body = response_model.model_dump_json(by_alias=True).encode("utf-8")

    return Response(content=final_body, media_type="application/json")