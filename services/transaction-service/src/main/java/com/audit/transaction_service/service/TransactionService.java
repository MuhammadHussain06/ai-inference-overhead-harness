package com.audit.transaction_service.service;

import com.audit.transaction_service.dto.AiRequestDto;
import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.exception.UpstreamInferenceException;
import com.audit.transaction_service.model.Transaction;
import com.audit.transaction_service.repository.TransactionRepository;
import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Mono;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
@Service
public class TransactionService {

    private static final Set<Integer> VALID_FEATURE_TIERS = Set.of(5, 10, 20, 28);

    private final TransactionRepository transactionRepository;
    private final WebClient webClient;

    @Value("${app.db.save.enabled:true}")
    private boolean dbSaveEnabled;

    public TransactionService(TransactionRepository transactionRepository, WebClient webClient) {
        this.transactionRepository = transactionRepository;
        this.webClient = webClient;
    }

    public Mono<ResponseDto> processTransaction(RequestDto request, long requestStartNanos) {
        long overallStartTime = System.nanoTime();

        if (request == null || request.getAmount() == null || request.getAmount().compareTo(BigDecimal.ZERO) <= 0) {
            String txIdStr = (request != null && request.getTransactionId() != null) ? request.getTransactionId() : "UNKNOWN";
            log.error("[Transaction ID: {}] Rejecting processing: Payload is null or amount <= 0.", txIdStr);
            return Mono.error(new IllegalArgumentException(
                    String.format("[Transaction ID: %s] Transaction payload and amount must be present and > 0.", txIdStr)
            ));
        }
        String strategy = request.getStrategy().toUpperCase();
        String endpoint;
        Integer featureTier = null;

        switch (strategy) {
            case "DISTRIBUTED_AI_SYNCHRONOUS":
                featureTier = request.getFeatureTier();
                if (featureTier == null || !VALID_FEATURE_TIERS.contains(featureTier)) {
                    return Mono.error(new IllegalArgumentException(
                            "featureTier must be one of " + VALID_FEATURE_TIERS + " for strategy DISTRIBUTED_AI_SYNCHRONOUS, got: " + featureTier));
                }
                List<Double> features = request.getFeatures();
                if (features == null || features.size() < featureTier) {
                    return Mono.error(new IllegalArgumentException(
                            "features must contain at least " + featureTier + " values for the selected tier, got: "
                                    + (features == null ? 0 : features.size())));
                }
                endpoint = "/predict/v" + featureTier;
                break;
            case "DISTRIBUTED_MOCK_GATEWAY":
                endpoint = "/predict/mock";
                break;
            default:
                return Mono.error(new IllegalArgumentException("Invalid evaluation strategy topology provided: " + strategy));
        }


        double requestParsingTimeMs = (System.nanoTime() - requestStartNanos) / 1_000_000.0;

        log.info("[Transaction ID: {}] Sending HTTP POST to Python endpoint {}", request.getTransactionId(), endpoint);
        long netStart = System.nanoTime();

        AiRequestDto aiPayload = new AiRequestDto(
                request.getTransactionId(),
                request.getAmount().doubleValue(),
                request.getFeatures()
        );

        return webClient.post()
                .uri(endpoint)
                .bodyValue(aiPayload)
                .retrieve()
                .bodyToMono(AiRiskResponse.class)
                .map(aiResponse -> {
                    double aiCallRoundTripTimeMs = (System.nanoTime() - netStart) / 1_000_000.0;
                    double riskScore = (aiResponse != null) ? aiResponse.getRiskScore() : 0.0;
                    boolean isFraud = (aiResponse != null) && aiResponse.isFraud();
                    ResponseDto.PythonTelemetryDto pythonTelemetry = (aiResponse != null && aiResponse.getPythonTelemetry() != null)
                            ? aiResponse.getPythonTelemetry()
                            : new ResponseDto.PythonTelemetryDto();

                    return new IntermediateResult(riskScore, isFraud, aiCallRoundTripTimeMs, pythonTelemetry);
                })

                .onErrorMap(e -> !(e instanceof UpstreamInferenceException), e -> {
                    log.error("[Transaction ID: {}] Failed to communicate with Python endpoint {}: {}",
                            request.getTransactionId(), endpoint, e.getMessage());

                    // Distinguish "Python rejected the input" (4xx from Python -- surfaced
                    // as our own 400) from "the call to Python didn't complete normally"
                    // (unreachable, timed out, or an unexpected 5xx -- surfaced as 502).
                    HttpStatus upstreamStatus = HttpStatus.BAD_GATEWAY;
                    if (e instanceof WebClientResponseException wcre) {
                        HttpStatusCode sc = wcre.getStatusCode();
                        if (sc.is4xxClientError()) {
                            upstreamStatus = HttpStatus.BAD_REQUEST;
                        }
                    }

                    return new UpstreamInferenceException(
                            String.format("[Transaction ID: %s] Upstream call to %s failed: %s",
                                    request.getTransactionId(), endpoint, e.getMessage()),
                            e, upstreamStatus);
                })
                .flatMap(intermediate -> {
                    double riskScore = intermediate.riskScore;
                    boolean isFraud = intermediate.isFraud;
                    double aiCallRoundTripTimeMs = intermediate.aiCallRoundTripTimeMs;
                    ResponseDto.PythonTelemetryDto pythonTelemetry = intermediate.pythonTelemetry;

                    String status = isFraud ? "FLAGGED" : "APPROVED";

                    if (dbSaveEnabled) {
                        Transaction entity = new Transaction();
                        entity.setTransactionId(request.getTransactionId());
                        entity.setAccountId(request.getAccountId());
                        entity.setTransactionAmount(request.getAmount());
                        entity.setTransactionType(request.getTransactionType());
                        entity.setFeatureTier(request.getFeatureTier());
                        if (request.getFeatures() != null) {
                            entity.setFeaturesCsv(request.getFeatures().stream()
                                    .map(String::valueOf)
                                    .collect(Collectors.joining(",")));
                        }
                        entity.setRiskScore(riskScore);
                        entity.setTransactionStatus(status);
                        entity.setEvaluationStrategy(strategy);

                        long dbStart = System.nanoTime();
                        return transactionRepository.save(entity)
                                .doOnSuccess(saved -> log.debug("[Transaction ID: {}] Saved to H2 database.", request.getTransactionId()))
                                .map(savedEntity -> {
                                    double dbWriteTimeMs = (System.nanoTime() - dbStart) / 1_000_000.0;
                                    return buildResponse(request, riskScore, status, strategy,
                                            overallStartTime, requestParsingTimeMs, aiCallRoundTripTimeMs,
                                            dbWriteTimeMs, pythonTelemetry);
                                });
                    } else {
                        log.debug("[Transaction ID: {}] DB persistence bypassed via configuration flag.", request.getTransactionId());
                        return Mono.fromCallable(() -> buildResponse(request, riskScore, status, strategy, overallStartTime,
                                requestParsingTimeMs, aiCallRoundTripTimeMs, 0.0, pythonTelemetry));
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
        response.setFeatureTier(request.getFeatureTier());
        response.setRequestParsingTimeMs(parseTime);
        response.setAiCallRoundTripTimeMs(netTime);

        double estimatedNetworkOverheadMs = netTime - pythonTelemetry.getTotalPythonExecutionTimeMs();
        response.setEstimatedNetworkOverheadMs(estimatedNetworkOverheadMs);
        response.setDbWriteTimeMs(dbTime);
        response.setPythonTelemetry(pythonTelemetry);
        response.setResponseSerializationTimeMs((System.nanoTime() - responseBuildStart) / 1_000_000.0);

        return response;
    }

    private static class IntermediateResult {
        double riskScore;
        boolean isFraud;
        double aiCallRoundTripTimeMs;
        ResponseDto.PythonTelemetryDto pythonTelemetry;

        public IntermediateResult(double riskScore, boolean isFraud, double aiCallRoundTripTimeMs, ResponseDto.PythonTelemetryDto pythonTelemetry) {
            this.riskScore = riskScore;
            this.isFraud = isFraud;
            this.aiCallRoundTripTimeMs = aiCallRoundTripTimeMs;
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