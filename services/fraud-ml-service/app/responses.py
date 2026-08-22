import time

from fastapi import Response

from .schemas import PythonTelemetryDto, TransactionResponse


def build_response(payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
                   dataframe_construction_time_ms=0.0, model_inference_time_ms=0.0,
                   thread_dispatch_time_ms=0.0, compute_stall_time_ms=0.0):
    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        threadDispatchTimeMs=thread_dispatch_time_ms,
        computationTimeMs=comp_time_ms,
        dataframeConstructionTimeMs=dataframe_construction_time_ms,
        modelInferenceTimeMs=model_inference_time_ms,
        computeStallMs=compute_stall_time_ms,
    )

    response_model = TransactionResponse(
        transactionId=payload.transactionId,
        isFraud=is_fraud,
        riskScore=risk_score,
        pythonTelemetry=telemetry,
    )

    # A response can't report the cost of producing itself without being
    # serialized twice. We time one pass as an estimate for the pass that
    # actually gets sent, since the two are the same shape and near-identical
    # size (only the digits in the telemetry floats differ).
    start_serial = time.perf_counter()
    response_model.model_dump_json(by_alias=True)
    estimated_serialization_ms = (time.perf_counter() - start_serial) * 1000

    response_model.pythonTelemetry.serializationResponseTimeMs = estimated_serialization_ms
    response_model.pythonTelemetry.totalPythonExecutionTimeMs = (
            (time.perf_counter() - start_total) * 1000 + estimated_serialization_ms
    )
    final_body = response_model.model_dump_json(by_alias=True).encode("utf-8")

    return Response(content=final_body, media_type="application/json")