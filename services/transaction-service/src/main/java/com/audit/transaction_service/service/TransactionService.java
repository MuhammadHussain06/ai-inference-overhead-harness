package com.audit.transaction_service.service;

import com.audit.transaction_service.dto.AiRequestDto;
import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.model.Transaction;
import com.audit.transaction_service.repository.TransactionRepository;
import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.math.BigDecimal;

@Slf4j
@Service
public class TransactionService {

    private final TransactionRepository transactionRepository;
    private final WebClient webClient;

    @Value("${app.db.save.enabled:true}")
    private boolean dbSaveEnabled;

    public TransactionService(TransactionRepository transactionRepository, WebClient webClient) {
        this.transactionRepository = transactionRepository;
        this.webClient = webClient;
    }

    public Mono<ResponseDto> processTransaction(RequestDto request) {
        long overallStartTime = System.nanoTime();

        long parseStart = System.nanoTime();
        if (request == null || request.getAmount() == null || request.getAmount().compareTo(BigDecimal.ZERO) <= 0) {
            String txIdStr = (request != null && request.getTransactionId() != null) ? request.getTransactionId() : "UNKNOWN";
            log.error("[Transaction ID: {}] Rejecting processing: Payload is null or amount <= 0.", txIdStr);
            return Mono.error(new IllegalArgumentException(
                    String.format("[Transaction ID: %s] Transaction payload and amount must be present and > 0.", txIdStr)
            ));
        }
        double requestParsingTimeMs = (System.nanoTime() - parseStart) / 1_000_000.0;

        String strategy = request.getStrategy().toUpperCase();
        String endpoint;

        switch (strategy) {
            case "DISTRIBUTED_AI_SYNCHRONOUS":
                endpoint = "/predict";
                break;
            case "DISTRIBUTED_MOCK_GATEWAY":
                endpoint = "/predict/mock";
                break;
            default:
                return Mono.error(new IllegalArgumentException("Invalid evaluation strategy topology provided: " + strategy));
        }

        log.info("[Transaction ID: {}] Sending HTTP POST to Python endpoint {}", request.getTransactionId(), endpoint);
        long netStart = System.nanoTime();

        AiRequestDto aiPayload = new AiRequestDto(
                request.getTransactionId(),
                request.getAmount().doubleValue(),
                request.getV1(),
                request.getV2(),
                request.getV3(),
                request.getV4(),
                request.getV5()
        );

        return webClient.post()
                .uri(endpoint)
                .bodyValue(aiPayload)
                .retrieve()
                .bodyToMono(AiRiskResponse.class)
                .map(aiResponse -> {
                    double networkCommunicationTimeMs = (System.nanoTime() - netStart) / 1_000_000.0;
                    double riskScore = (aiResponse != null) ? aiResponse.getRiskScore() : 0.0;
                    boolean isFraud = (aiResponse != null) && aiResponse.isFraud();
                    ResponseDto.PythonTelemetryDto pythonTelemetry = (aiResponse != null && aiResponse.getPythonTelemetry() != null)
                            ? aiResponse.getPythonTelemetry()
                            : new ResponseDto.PythonTelemetryDto();

                    return new IntermediateResult(riskScore, isFraud, networkCommunicationTimeMs, pythonTelemetry);
                })
                .onErrorResume(e -> {
                    double networkCommunicationTimeMs = (System.nanoTime() - netStart) / 1_000_000.0;
                    log.error("[Transaction ID: {}] Failed to communicate with Python endpoint {}: {}",
                            request.getTransactionId(), endpoint, e.getMessage());
                    return Mono.just(new IntermediateResult(0.0, false, networkCommunicationTimeMs, new ResponseDto.PythonTelemetryDto()));
                })
                .flatMap(intermediate -> {
                    double riskScore = intermediate.riskScore;
                    boolean isFraud = intermediate.isFraud;
                    double networkCommunicationTimeMs = intermediate.networkTimeMs;
                    ResponseDto.PythonTelemetryDto pythonTelemetry = intermediate.pythonTelemetry;

                    String status = isFraud ? "FLAGGED" : "APPROVED";
                    long dbStart = System.nanoTime();
                    double currentExecutionTimeMs = (System.nanoTime() - overallStartTime) / 1_000_000.0;

                    if (dbSaveEnabled) {
                        Transaction entity = new Transaction();
                        entity.setTransactionId(request.getTransactionId());
                        entity.setAccountId(request.getAccountId());
                        entity.setTransactionAmount(request.getAmount());
                        entity.setTransactionType(request.getTransactionType());
                        entity.setV1(request.getV1());
                        entity.setV2(request.getV2());
                        entity.setV3(request.getV3());
                        entity.setV4(request.getV4());
                        entity.setV5(request.getV5());
                        entity.setRiskScore(riskScore);
                        entity.setTransactionStatus(status);
                        entity.setEvaluationStrategy(strategy);
                        entity.setExecutionTimeMs(currentExecutionTimeMs);

                        return transactionRepository.save(entity)
                                .doOnSuccess(saved -> log.debug("[Transaction ID: {}] Saved to H2 database.", request.getTransactionId()))
                                .map(savedEntity -> buildResponse(request, riskScore, status, strategy, overallStartTime,
                                        requestParsingTimeMs, networkCommunicationTimeMs,
                                        (System.nanoTime() - dbStart) / 1_000_000.0, pythonTelemetry));
                    } else {
                        log.debug("[Transaction ID: {}] DB persistence bypassed via configuration flag.", request.getTransactionId());
                        return Mono.fromCallable(() -> buildResponse(request, riskScore, status, strategy, overallStartTime,
                                requestParsingTimeMs, networkCommunicationTimeMs, 0.0, pythonTelemetry));
                    }
                });
    }

    private ResponseDto buildResponse(RequestDto request, double riskScore, String status, String strategy,
                                      long overallStartTime, double parseTime, double netTime,
                                      double dbTime, ResponseDto.PythonTelemetryDto pythonTelemetry) {
        long responseBuildStart = System.nanoTime();
        double executionTimeMs = (System.nanoTime() - overallStartTime) / 1_000_000.0;

        log.info("[Transaction ID: {}] Executed strategy [{}] in {} ms | Status: {}",
                request.getTransactionId(), strategy, executionTimeMs, status);

        ResponseDto response = new ResponseDto(
                request.getTransactionId(),
                riskScore,
                status,
                strategy,
                executionTimeMs
        );
        response.setAccountId(request.getAccountId());
        response.setAmount(request.getAmount());
        response.setTransactionType(request.getTransactionType());

        response.setRequestParsingTimeMs(parseTime);
        response.setNetworkCommunicationTimeMs(netTime);
        response.setDbWriteTimeMs(dbTime);
        response.setPythonTelemetry(pythonTelemetry);
        response.setResponseSerializationTimeMs((System.nanoTime() - responseBuildStart) / 1_000_000.0);

        return response;
    }

    private static class IntermediateResult {
        double riskScore;
        boolean isFraud;
        double networkTimeMs;
        ResponseDto.PythonTelemetryDto pythonTelemetry;

        public IntermediateResult(double riskScore, boolean isFraud, double networkTimeMs, ResponseDto.PythonTelemetryDto pythonTelemetry) {
            this.riskScore = riskScore;
            this.isFraud = isFraud;
            this.networkTimeMs = networkTimeMs;
            this.pythonTelemetry = pythonTelemetry;
        }
    }


    private static class AiRiskResponse {
        @JsonProperty("isFraud")
        private boolean isFraud;

        @JsonProperty("riskScore")
        private double riskScore;

        @JsonProperty("pythonTelemetry")
        private ResponseDto.PythonTelemetryDto pythonTelemetry;

        public boolean isFraud() { return isFraud; }
        public void setFraud(boolean fraud) { isFraud = fraud; }

        public double getRiskScore() { return riskScore; }
        public void setRiskScore(double riskScore) { this.riskScore = riskScore; }

        public ResponseDto.PythonTelemetryDto getPythonTelemetry() { return pythonTelemetry; }
        public void setPythonTelemetry(ResponseDto.PythonTelemetryDto pythonTelemetry) { this.pythonTelemetry = pythonTelemetry; }
    }
}
