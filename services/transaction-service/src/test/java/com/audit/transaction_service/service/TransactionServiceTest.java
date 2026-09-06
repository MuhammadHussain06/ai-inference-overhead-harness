package com.audit.transaction_service.service;

import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.exception.UpstreamInferenceException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.reactive.function.client.ClientResponse;
import org.springframework.web.reactive.function.client.ExchangeFunction;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;
import reactor.test.StepVerifier;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

/**
 * Guards the Java-side measurement constructs the paper reports: the network-overhead
 * derivation, telemetry pass-through, and strategy routing.
 */
class TransactionServiceTest {

    private static final Set<Integer> VALID_TIERS = Set.of(5, 10, 20, 28);
    private static final String TX_ID = "11111111-2222-3333-4444-555555555555";

    /** Every telemetry field carries a distinct value so a mis-mapping cannot pass. */
    private static final String TELEMETRY_JSON = """
            {"parsingRequestTimeMs":0.11,"threadDispatchTimeMs":0.22,"computationTimeMs":0.33,
             "dataframeConstructionTimeMs":0.44,"modelInferenceTimeMs":0.55,"computeStallMs":0.66,
             "serializationResponseTimeMs":0.77,"totalPythonExecutionTimeMs":0.88}""";

    private static String pythonResponse(String telemetryJson) {
        return """
                {"transactionId":"%s","isFraud":true,"riskScore":0.91,"pythonTelemetry":%s}"""
                .formatted(TX_ID, telemetryJson);
    }

    private static FeatureTierRegistry registryOf(Set<Integer> tiers) {
        return new FeatureTierRegistry(null) {
            @Override
            public Set<Integer> getValidTiers() {
                return tiers;
            }
        };
    }

    private static TransactionService serviceReturning(String body, AtomicReference<String> uriSink) {
        ExchangeFunction stub = request -> {
            if (uriSink != null) {
                uriSink.set(request.url().getPath());
            }
            return Mono.just(ClientResponse.create(HttpStatus.OK)
                    .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                    .body(body)
                    .build());
        };
        WebClient client = WebClient.builder()
                .baseUrl("http://python:8000")
                .exchangeFunction(stub)
                .build();
        return new TransactionService(null, client, registryOf(VALID_TIERS));
    }

    private static TransactionService serviceFailingWith(HttpStatus status) {
        ExchangeFunction stub = request -> Mono.just(ClientResponse.create(status).body("upstream failed").build());
        WebClient client = WebClient.builder()
                .baseUrl("http://python:8000")
                .exchangeFunction(stub)
                .build();
        return new TransactionService(null, client, registryOf(VALID_TIERS));
    }

    private static RequestDto request(String strategy, Integer featureTier) {
        RequestDto dto = new RequestDto();
        dto.setTransactionId(TX_ID);
        dto.setAccountId("ACC-1000");
        dto.setAmount(BigDecimal.valueOf(100.0));
        dto.setTransactionType("PURCHASE");
        dto.setFeatures(java.util.Collections.nCopies(28, 0.5));
        dto.setStrategy(strategy);
        dto.setFeatureTier(featureTier);
        return dto;
    }

    private static ResponseDto call(TransactionService service, RequestDto request) {
        return service.processTransaction(request, System.nanoTime()).block();
    }

    // network overhead derivation

    @Test
    void networkOverheadIsRoundTripMinusPythonTotal() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getEstimatedNetworkOverheadMs()).isEqualTo(
                response.getAiCallRoundTripTimeMs()
                        - response.getPythonTelemetry().getTotalPythonExecutionTimeMs());
    }

    @Test
    void negativeNetworkOverheadIsPreservedNotClamped() {
        String inflated = TELEMETRY_JSON.replace("\"totalPythonExecutionTimeMs\":0.88",
                "\"totalPythonExecutionTimeMs\":100000.0");

        ResponseDto response = call(serviceReturning(pythonResponse(inflated), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getEstimatedNetworkOverheadMs()).isNegative();
    }

    @Test
    void roundTripIsPositiveAndBoundedByTotalExecutionTime() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getAiCallRoundTripTimeMs()).isPositive();
        assertThat(response.getExecutionTimeMs()).isGreaterThanOrEqualTo(response.getAiCallRoundTripTimeMs());
    }

    @Test
    void executionTimeIsMeasuredFromTheSuppliedRequestStart() {
        long fiftyMillisAgo = System.nanoTime() - 50_000_000L;

        ResponseDto response = serviceReturning(pythonResponse(TELEMETRY_JSON), null)
                .processTransaction(request("DISTRIBUTED_AI_SYNCHRONOUS", 5), fiftyMillisAgo)
                .block();

        assertThat(response.getExecutionTimeMs()).isGreaterThanOrEqualTo(50.0);
    }

    // telemetry pass through

    @Test
    void everyTelemetryFieldSurvivesTheUpstreamHop() {
        ResponseDto.PythonTelemetryDto telemetry =
                call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                        request("DISTRIBUTED_AI_SYNCHRONOUS", 5)).getPythonTelemetry();

        assertThat(telemetry.getParsingRequestTimeMs()).isEqualTo(0.11);
        assertThat(telemetry.getThreadDispatchTimeMs()).isEqualTo(0.22);
        assertThat(telemetry.getComputationTimeMs()).isEqualTo(0.33);
        assertThat(telemetry.getDataframeConstructionTimeMs()).isEqualTo(0.44);
        assertThat(telemetry.getModelInferenceTimeMs()).isEqualTo(0.55);
        assertThat(telemetry.getComputeStallMs()).isEqualTo(0.66);
        assertThat(telemetry.getSerializationResponseTimeMs()).isEqualTo(0.77);
        assertThat(telemetry.getTotalPythonExecutionTimeMs()).isEqualTo(0.88);
    }

    @Test
    void unknownPythonTelemetryFieldsAreIgnored() {
        String extended = TELEMETRY_JSON.replace("}", ",\"someFutureMetricMs\":1.23}");

        ResponseDto response = call(serviceReturning(pythonResponse(extended), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getPythonTelemetry().getTotalPythonExecutionTimeMs()).isEqualTo(0.88);
    }

    @Test
    void absentTelemetryYieldsZeroedFieldsRatherThanFailing() {
        String withoutTelemetry = """
                {"transactionId":"%s","isFraud":false,"riskScore":0.1}""".formatted(TX_ID);

        ResponseDto.PythonTelemetryDto telemetry =
                call(serviceReturning(withoutTelemetry, null),
                        request("DISTRIBUTED_AI_SYNCHRONOUS", 5)).getPythonTelemetry();

        assertThat(telemetry).isNotNull();
        assertThat(telemetry.getTotalPythonExecutionTimeMs()).isEqualTo(0.0);
    }

    @Test
    void verdictAndScoreArePassedThrough() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getRiskScore()).isCloseTo(0.91, within(1e-9));
        assertThat(response.getTransactionStatus()).isEqualTo("FLAGGED");
    }

    @Test
    void requestIdentityIsEchoedBack() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 20));

        assertThat(response.getTransactionId()).isEqualTo(TX_ID);
        assertThat(response.getAccountId()).isEqualTo("ACC-1000");
        assertThat(response.getTransactionType()).isEqualTo("PURCHASE");
        assertThat(response.getFeatureTier()).isEqualTo(20);
    }

    @Test
    void dbWriteTimeIsZeroWhilePersistenceIsDisabled() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_AI_SYNCHRONOUS", 5));

        assertThat(response.getDbWriteTimeMs()).isEqualTo(0.0);
    }

    // strategy routing

    @ParameterizedTest
    @CsvSource({
            "DISTRIBUTED_AI_SYNCHRONOUS, 5,  /predict/v5",
            "DISTRIBUTED_AI_SYNCHRONOUS, 28, /predict/v28",
            "DISTRIBUTED_MOCK_GATEWAY,   ,   /predict/mock",
            "DISTRIBUTED_CALIBRATION_ONLY,,  /predict/calibrate",
    })
    void strategyRoutesToItsOwnEndpoint(String strategy, Integer tier, String expectedPath) {
        AtomicReference<String> uri = new AtomicReference<>();

        call(serviceReturning(pythonResponse(TELEMETRY_JSON), uri), request(strategy, tier));

        assertThat(uri.get()).isEqualTo(expectedPath);
    }

    @Test
    void strategyMatchingIsCaseInsensitive() {
        AtomicReference<String> uri = new AtomicReference<>();

        call(serviceReturning(pythonResponse(TELEMETRY_JSON), uri),
                request("distributed_ai_synchronous", 10));

        assertThat(uri.get()).isEqualTo("/predict/v10");
    }

    @Test
    void baselineStrategiesReportNoFeatureTier() {
        ResponseDto response = call(serviceReturning(pythonResponse(TELEMETRY_JSON), null),
                request("DISTRIBUTED_MOCK_GATEWAY", 28));

        assertThat(response.getFeatureTier()).isNull();
    }

    // input rejection

    @ParameterizedTest
    @ValueSource(ints = {0, 7, 27, 29})
    void unconfiguredFeatureTierIsRejected(int tier) {
        StepVerifier.create(serviceReturning(pythonResponse(TELEMETRY_JSON), null)
                        .processTransaction(request("DISTRIBUTED_AI_SYNCHRONOUS", tier), System.nanoTime()))
                .expectError(IllegalArgumentException.class)
                .verify();
    }

    @Test
    void missingFeatureTierIsRejectedForTheAiStrategy() {
        StepVerifier.create(serviceReturning(pythonResponse(TELEMETRY_JSON), null)
                        .processTransaction(request("DISTRIBUTED_AI_SYNCHRONOUS", null), System.nanoTime()))
                .expectError(IllegalArgumentException.class)
                .verify();
    }

    @Test
    void tooFewFeaturesForTheSelectedTierIsRejected() {
        RequestDto short20 = request("DISTRIBUTED_AI_SYNCHRONOUS", 20);
        short20.setFeatures(List.of(0.1, 0.2, 0.3));

        StepVerifier.create(serviceReturning(pythonResponse(TELEMETRY_JSON), null)
                        .processTransaction(short20, System.nanoTime()))
                .expectError(IllegalArgumentException.class)
                .verify();
    }

    @Test
    void unknownStrategyIsRejected() {
        StepVerifier.create(serviceReturning(pythonResponse(TELEMETRY_JSON), null)
                        .processTransaction(request("SOMETHING_ELSE", null), System.nanoTime()))
                .expectError(IllegalArgumentException.class)
                .verify();
    }

    // upstream failure mapping

    @Test
    void upstreamServerErrorBecomesBadGateway() {
        StepVerifier.create(serviceFailingWith(HttpStatus.INTERNAL_SERVER_ERROR)
                        .processTransaction(request("DISTRIBUTED_AI_SYNCHRONOUS", 5), System.nanoTime()))
                .expectErrorSatisfies(error -> assertThat(((UpstreamInferenceException) error).getUpstreamStatus())
                        .isEqualTo(HttpStatus.BAD_GATEWAY))
                .verify();
    }

    @Test
    void upstreamClientErrorBecomesBadRequest() {
        StepVerifier.create(serviceFailingWith(HttpStatus.BAD_REQUEST)
                        .processTransaction(request("DISTRIBUTED_AI_SYNCHRONOUS", 5), System.nanoTime()))
                .expectErrorSatisfies(error -> assertThat(((UpstreamInferenceException) error).getUpstreamStatus())
                        .isEqualTo(HttpStatus.BAD_REQUEST))
                .verify();
    }
}