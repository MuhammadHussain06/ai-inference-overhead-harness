from typing import List

from pydantic import BaseModel, ConfigDict, Field


class TransactionPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    amount: float
    # default_factory, not default=[]: a shared mutable default would leak between requests.
    features: List[float] = Field(default_factory=list)


class PythonTelemetryDto(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    # Defaults of 0.0 keep the field set identical across all three strategy arms,
    # which is what makes decomposition by subtraction well defined.
    parsingRequestTimeMs: float = 0.0
    threadDispatchTimeMs: float = 0.0
    computationTimeMs: float = 0.0
    dataframeConstructionTimeMs: float = 0.0
    modelInferenceTimeMs: float = 0.0
    computeStallMs: float = 0.0
    serializationResponseTimeMs: float = 0.0
    totalPythonExecutionTimeMs: float = 0.0


class TransactionResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    isFraud: bool
    riskScore: float
    pythonTelemetry: PythonTelemetryDto