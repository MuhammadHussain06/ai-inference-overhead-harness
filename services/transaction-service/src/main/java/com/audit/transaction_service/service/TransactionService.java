package com.audit.transaction_service.service;

import com.audit.transaction_service.dto.AiRequestDto;
import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.exception.UpstreamInferenceException;
import com.audit.transaction_service.model.Transaction;
import com.audit.transaction_service.repository.TransactionRepository;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.core.publisher.Mono;

import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.stream.Collectors;

@Slf4j
@Service
public class TransactionService {

    private final TransactionRepository transactionRepository;
    private final WebClient webClient;
    private final FeatureTierRegistry featureTierRegistry;

    // Fail-safe default, matching application.properties; applies only if the
    // property is missing entirely.
    @Value("${app.db.save.enabled:false}")
    private boolean dbSaveEnabled;

    public TransactionService(TransactionRepository transactionRepository, WebClient webClient,
                              FeatureTierRegistry featureTierRegistry) {
        this.transactionRepository = transactionRepository;
        this.webClient = webClient;
        this.featureTierRegistry = featureTierRegistry;
    }

    public Mono<ResponseDto> processTransaction(RequestDto request, long requestStartNanos) {
        long overallStartTime = requestStartNanos;

        // Field-level rules are enforced by @Valid before this method runs; only the
        // cross-field arm (strategy) and tier rules are checked here. Locale.ROOT keeps
        // the uppercasing independent of the JVM default locale.
        String strategy = request.getStrategy().toUpperCase(Locale.ROOT);
        String endpoint;
        Integer featureTier = null;

        switch (strategy) {
            case "DISTRIBUTED_AI_SYNCHRONOUS":
                featureTier = request.getFeatureTier();
                Set<Integer> validTiers = featureTierRegistry.getValidTiers();
                if (featureTier == null || !validTiers.contains(featureTier)) {
                    return Mono.error(new IllegalArgumentException(
                            "featureTier must be one of " + validTiers + " for strategy DISTRIBUTED_AI_SYNCHRONOUS, got: " + featureTier));
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
            case "DISTRIBUTED_CALIBRATION_ONLY":
                // Calibration arm: same Python path, thread hand-off included, but no model
                // work; the floor that bounds instrumentation cost.
                endpoint = "/predict/calibrate";
                break;
            default:
                return Mono.error(new IllegalArgumentException("Invalid evaluation strategy topology provided: " + strategy));
        }


        final Integer resolvedFeatureTier = featureTier;

        // T0 to the end of the arm/tier checks: WebFlux dispatch, body decode, bean
        // validation and the switch above. Broader than deserialization, hence the name.
        double requestPreprocessingTimeMs = (System.nanoTime() - requestStartNanos) / 1_000_000.0;

        // Forwards the full feature list unsliced, so the body size does not vary with
        // tier; fraud-ml-service takes only the features each tier needs.
        AiRequestDto aiPayload = new AiRequestDto(
                request.getTransactionId(),
                request.getAmount().doubleValue(),
                request.getFeatures()
        );

        // Deferred so netStart is read at subscription, not at assembly. Otherwise the
        // gap until WebFlux subscribes (handler return, the controller's .map, result
        // handling) would be charged to aiCallRoundTripTimeMs and hence to the bridge.
        return Mono.defer(() -> {
                    long netStart = System.nanoTime();
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
                            });
                })

                .onErrorMap(e -> !(e instanceof UpstreamInferenceException), e -> {
                    log.error("[Transaction ID: {}] Failed to communicate with Python endpoint {}: {}",
                            request.getTransactionId(), endpoint, e.getMessage());

                    // Timeout (direct or as the immediate cause) -> 504; upstream 4xx -> 400;
                    // anything else (unreachable, upstream 5xx) -> 502.
                    boolean isTimeout = e instanceof java.util.concurrent.TimeoutException
                            || e instanceof io.netty.handler.timeout.ReadTimeoutException
                            || (e.getCause() != null
                            && (e.getCause() instanceof java.util.concurrent.TimeoutException
                            || e.getCause() instanceof io.netty.handler.timeout.ReadTimeoutException));

                    HttpStatus upstreamStatus = isTimeout ? HttpStatus.GATEWAY_TIMEOUT : HttpStatus.BAD_GATEWAY;
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
                        entity.setFeatureTier(resolvedFeatureTier);
                        if (request.getFeatures() != null) {
                            entity.setFeaturesCsv(request.getFeatures().stream()
                                    .map(String::valueOf)
                                    .collect(Collectors.joining(",")));
                        }
                        entity.setRiskScore(riskScore);
                        entity.setTransactionStatus(status);
                        entity.setEvaluationStrategy(strategy);
                        // Pre-save snapshot; excludes DB write time, unlike the response's executionTimeMs.
                        entity.setExecutionTimeMs((System.nanoTime() - overallStartTime) / 1_000_000.0);

                        long dbStart = System.nanoTime();
                        return transactionRepository.save(entity)
                                .doOnSuccess(saved -> log.debug("[Transaction ID: {}] Saved to H2 database.", request.getTransactionId()))
                                .map(savedEntity -> {
                                    double dbWriteTimeMs = (System.nanoTime() - dbStart) / 1_000_000.0;
                                    return buildResponse(request, riskScore, status, strategy, resolvedFeatureTier,
                                            overallStartTime, requestPreprocessingTimeMs, aiCallRoundTripTimeMs,
                                            dbWriteTimeMs, pythonTelemetry);
                                });
                    } else {
                        return Mono.fromCallable(() -> buildResponse(request, riskScore, status, strategy, resolvedFeatureTier,
                                overallStartTime, requestPreprocessingTimeMs, aiCallRoundTripTimeMs, 0.0, pythonTelemetry));
                    }
                });
    }

    private ResponseDto buildResponse(RequestDto request, double riskScore, String status, String strategy,
                                      Integer featureTier, long overallStartTime, double preprocessingTime, double netTime,
                                      double dbTime, ResponseDto.PythonTelemetryDto pythonTelemetry) {
        // executionTimeMs is read first, so it excludes the DTO build that
        // responseObjectBuildTimeMs times. Neither includes WebFlux's encoding of the
        // response body; that falls in the client-side remainder.
        double executionTimeMs = (System.nanoTime() - overallStartTime) / 1_000_000.0;
        long responseBuildStart = System.nanoTime();

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
        response.setFeatureTier(featureTier);
        response.setRequestPreprocessingTimeMs(preprocessingTime);
        response.setAiCallRoundTripTimeMs(netTime);

        // Estimated bridge overhead, unclamped: a negative value means Python's reported
        // total exceeded Java's round trip, a measurement signal that clamping would hide
        // while biasing the mean upward. analyze-results.py reports the rate and minimum
        // per tier.
        double estimatedBridgeOverheadMs = netTime - pythonTelemetry.getTotalPythonExecutionTimeMs();
        response.setEstimatedBridgeOverheadMs(estimatedBridgeOverheadMs);
        response.setDbWriteTimeMs(dbTime);
        response.setPythonTelemetry(pythonTelemetry);
        response.setResponseObjectBuildTimeMs((System.nanoTime() - responseBuildStart) / 1_000_000.0);

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


    // Ignores unknown fields so Python telemetry additions do not break Jackson deserialization.
    @JsonIgnoreProperties(ignoreUnknown = true)
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