from pydantic import BaseModel, ConfigDict, Field



class TransactionPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    amount: float
    v1: float = 0.0
    v2: float = 0.0
    v3: float = 0.0
    v4: float = 0.0
    v5: float = 0.0


class PythonTelemetryDto(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    parsingRequestTimeMs: float = 0.0
    computationTimeMs: float = 0.0
    serializationResponseTimeMs: float = 0.0
    totalPythonExecutionTimeMs: float = 0.0


class TransactionResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    transactionId: str
    isFraud: bool = Field(..., alias="isFraud")
    riskScore: float = Field(..., alias="riskScore")
    message: str
    pythonTelemetry: PythonTelemetryDto
