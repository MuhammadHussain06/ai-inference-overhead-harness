from typing import List

from pydantic import BaseModel, ConfigDict, Field



class TransactionPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    amount: float
    features: List[float] = Field(default_factory=list)


class PythonTelemetryDto(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    parsingRequestTimeMs: float = 0.0
    computationTimeMs: float = 0.0
    dataframeConstructionTimeMs: float = 0.0
    modelInferenceTimeMs: float = 0.0
    serializationResponseTimeMs: float = 0.0
    totalPythonExecutionTimeMs: float = 0.0


class TransactionResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    isFraud: bool = Field(..., alias="isFraud")
    riskScore: float = Field(..., alias="riskScore")
    pythonTelemetry: PythonTelemetryDto