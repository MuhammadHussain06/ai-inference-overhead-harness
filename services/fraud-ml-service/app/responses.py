import time

from fastapi import Response

from .schemas import PythonTelemetryDto, TransactionResponse

# Serialization cost cannot be measured in the live path: the field reporting it sits
# inside the object being serialized. An EWMA of previous requests' measured cost
# stands in. build_response runs on the event loop, so this global has one writer
# per worker process.
_serialization_estimate_ms = None
_EWMA_ALPHA = 0.1


def calibrate_serialization_estimate(n_warmup: int = 20) -> float:
    """Seeds the estimate by serializing a structurally identical template response."""
    global _serialization_estimate_ms

    template = TransactionResponse(
        transactionId="00000000-0000-0000-0000-000000000000",
        isFraud=False,
        riskScore=0.0,
        pythonTelemetry=PythonTelemetryDto(),
    )
    samples = []
    for _ in range(n_warmup):
        start = time.perf_counter()
        template.model_dump_json(by_alias=True)
        samples.append((time.perf_counter() - start) * 1000)

    _serialization_estimate_ms = sum(samples) / len(samples)
    return _serialization_estimate_ms


def get_serialization_estimate() -> float:
    """Current EWMA estimate, exposed on /health so its magnitude is reportable."""
    return _serialization_estimate_ms if _serialization_estimate_ms is not None else 0.0


def build_response(payload, is_fraud, risk_score, parsing_time_ms, comp_time_ms, start_total,
                   dataframe_construction_time_ms=0.0, model_inference_time_ms=0.0,
                   thread_dispatch_time_ms=0.0, compute_stall_time_ms=0.0):
    global _serialization_estimate_ms
    if _serialization_estimate_ms is None:
        calibrate_serialization_estimate()  # fallback when startup seeding was skipped

    # Snapshots the estimate before the update below, so the value the response
    # reports is the same one folded into its own total.
    telemetry = PythonTelemetryDto(
        parsingRequestTimeMs=parsing_time_ms,
        threadDispatchTimeMs=thread_dispatch_time_ms,
        computationTimeMs=comp_time_ms,
        dataframeConstructionTimeMs=dataframe_construction_time_ms,
        modelInferenceTimeMs=model_inference_time_ms,
        computeStallMs=compute_stall_time_ms,
        serializationResponseTimeMs=_serialization_estimate_ms,
    )

    response_model = TransactionResponse(
        transactionId=payload.transactionId,
        isFraud=is_fraud,
        riskScore=risk_score,
        pythonTelemetry=telemetry,
    )

    # start_total is the middleware stamp, so this spans the full Python-side wall
    # time. Set before the one serialize call below; those bytes are final.
    response_model.pythonTelemetry.totalPythonExecutionTimeMs = (
            (time.perf_counter() - start_total) * 1000 + _serialization_estimate_ms
    )

    start_serial = time.perf_counter()
    final_body = response_model.model_dump_json(by_alias=True).encode("utf-8")
    actual_serialization_ms = (time.perf_counter() - start_serial) * 1000

    _serialization_estimate_ms = (
            (1 - _EWMA_ALPHA) * _serialization_estimate_ms + _EWMA_ALPHA * actual_serialization_ms
    )

    return Response(content=final_body, media_type="application/json")