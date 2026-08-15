package com.audit.transaction_service.dto;

import java.math.BigDecimal;

public class ResponseDto {

    private String transactionId;
    private String accountId;
    private BigDecimal amount;
    private String transactionType;
    private double riskScore;
    private String transactionStatus;

    private double executionTimeMs;
    private double requestParsingTimeMs;
    private double aiCallRoundTripTimeMs;
    private double estimatedNetworkOverheadMs;
    private double dbWriteTimeMs;
    private double responseSerializationTimeMs;

    private PythonTelemetryDto pythonTelemetry = new PythonTelemetryDto();

    private String strategy;

    // Number of features (V1..Vn) the scoring model actually used. Null for
    // DISTRIBUTED_MOCK_GATEWAY
    private Integer featureTier;

    public ResponseDto() {}

    public ResponseDto(String transactionId, double riskScore, String transactionStatus, String strategy, double executionTimeMs) {
        this.transactionId = transactionId;
        this.riskScore = riskScore;
        this.transactionStatus = transactionStatus;
        this.strategy = strategy;
        this.executionTimeMs = executionTimeMs;
    }

    public String getTransactionId() { return transactionId; }
    public void setTransactionId(String transactionId) { this.transactionId = transactionId; }

    public String getAccountId() { return accountId; }
    public void setAccountId(String accountId) { this.accountId = accountId; }

    public BigDecimal getAmount() { return amount; }
    public void setAmount(BigDecimal amount) { this.amount = amount; }

    public String getTransactionType() { return transactionType; }
    public void setTransactionType(String transactionType) { this.transactionType = transactionType; }

    public double getRiskScore() { return riskScore; }
    public void setRiskScore(double riskScore) { this.riskScore = riskScore; }

    public String getTransactionStatus() { return transactionStatus; }
    public void setTransactionStatus(String transactionStatus) { this.transactionStatus = transactionStatus; }

    public double getExecutionTimeMs() { return executionTimeMs; }
    public void setExecutionTimeMs(double executionTimeMs) { this.executionTimeMs = executionTimeMs; }

    public double getRequestParsingTimeMs() { return requestParsingTimeMs; }
    public void setRequestParsingTimeMs(double requestParsingTimeMs) { this.requestParsingTimeMs = requestParsingTimeMs; }

    public double getAiCallRoundTripTimeMs() { return aiCallRoundTripTimeMs; }
    public void setAiCallRoundTripTimeMs(double aiCallRoundTripTimeMs) { this.aiCallRoundTripTimeMs = aiCallRoundTripTimeMs; }

    public double getEstimatedNetworkOverheadMs() { return estimatedNetworkOverheadMs; }
    public void setEstimatedNetworkOverheadMs(double estimatedNetworkOverheadMs) { this.estimatedNetworkOverheadMs = estimatedNetworkOverheadMs; }

    public double getDbWriteTimeMs() { return dbWriteTimeMs; }
    public void setDbWriteTimeMs(double dbWriteTimeMs) { this.dbWriteTimeMs = dbWriteTimeMs; }

    public double getResponseSerializationTimeMs() { return responseSerializationTimeMs; }
    public void setResponseSerializationTimeMs(double responseSerializationTimeMs) { this.responseSerializationTimeMs = responseSerializationTimeMs; }

    public PythonTelemetryDto getPythonTelemetry() { return pythonTelemetry; }
    public void setPythonTelemetry(PythonTelemetryDto pythonTelemetry) { this.pythonTelemetry = pythonTelemetry; }

    public String getStrategy() { return strategy; }
    public void setStrategy(String strategy) { this.strategy = strategy; }

    public Integer getFeatureTier() { return featureTier; }
    public void setFeatureTier(Integer featureTier) { this.featureTier = featureTier; }

    public static class PythonTelemetryDto {
        private double parsingRequestTimeMs = 0.0;
        private double computationTimeMs = 0.0;
        private double dataframeConstructionTimeMs = 0.0;
        private double modelInferenceTimeMs = 0.0;
        private double serializationResponseTimeMs = 0.0;
        private double totalPythonExecutionTimeMs = 0.0;

        public PythonTelemetryDto() {}

        public double getParsingRequestTimeMs() { return parsingRequestTimeMs; }
        public void setParsingRequestTimeMs(double parsingRequestTimeMs) { this.parsingRequestTimeMs = parsingRequestTimeMs; }

        public double getComputationTimeMs() { return computationTimeMs; }
        public void setComputationTimeMs(double computationTimeMs) { this.computationTimeMs = computationTimeMs; }

        public double getDataframeConstructionTimeMs() { return dataframeConstructionTimeMs; }
        public void setDataframeConstructionTimeMs(double dataframeConstructionTimeMs) { this.dataframeConstructionTimeMs = dataframeConstructionTimeMs; }

        public double getModelInferenceTimeMs() { return modelInferenceTimeMs; }
        public void setModelInferenceTimeMs(double modelInferenceTimeMs) { this.modelInferenceTimeMs = modelInferenceTimeMs; }

        public double getSerializationResponseTimeMs() { return serializationResponseTimeMs; }
        public void setSerializationResponseTimeMs(double serializationResponseTimeMs) { this.serializationResponseTimeMs = serializationResponseTimeMs; }

        public double getTotalPythonExecutionTimeMs() { return totalPythonExecutionTimeMs; }
        public void setTotalPythonExecutionTimeMs(double totalPythonExecutionTimeMs) { this.totalPythonExecutionTimeMs = totalPythonExecutionTimeMs; }
    }
}