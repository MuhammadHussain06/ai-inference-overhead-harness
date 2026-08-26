package com.audit.transaction_service.service;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.annotation.PostConstruct;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

// Dynamically fetches valid feature tiers from Python's /health endpoint at startup,
// eliminating manual sync between Java and fraud-ml-service's FEATURE_TIERS.
@Slf4j
@Component
public class FeatureTierRegistry {

    private static final int MAX_ATTEMPTS = 30;
    private static final Duration RETRY_DELAY = Duration.ofSeconds(2);

    private final WebClient webClient;
    private Set<Integer> validTiers;

    public FeatureTierRegistry(WebClient webClient) {
        this.webClient = webClient;
    }

    // Runs during bean creation to fail application startup immediately if tier
    // initialization fails, preventing the server from starting with invalid state.
    @PostConstruct
    public void init() {
        RuntimeException lastError = null;
        for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            try {
                HealthResponse health = webClient.get()
                        .uri("/health")
                        .retrieve()
                        .bodyToMono(HealthResponse.class)
                        .block();
                if (health == null || health.loadedTiers == null || health.loadedTiers.isEmpty()) {
                    throw new IllegalStateException("fraud-ml-service /health returned no loadedTiers.");
                }
                validTiers = health.loadedTiers.stream().collect(Collectors.toUnmodifiableSet());
                log.info("[FeatureTierRegistry] Valid feature tiers (from fraud-ml-service /health): {}", validTiers);
                return;
            } catch (RuntimeException e) {
                lastError = e;
                log.warn("[FeatureTierRegistry] Attempt {}/{} to reach fraud-ml-service /health failed: {}",
                        attempt, MAX_ATTEMPTS, e.getMessage());
                sleepQuietly();
            }
        }
        throw new IllegalStateException(
                "Could not fetch valid feature tiers from fraud-ml-service /health after "
                        + MAX_ATTEMPTS + " attempts. transaction-service cannot start without this.", lastError);
    }

    public Set<Integer> getValidTiers() {
        return validTiers;
    }

    private void sleepQuietly() {
        try {
            Thread.sleep(RETRY_DELAY.toMillis());
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    private static class HealthResponse {
        @JsonProperty("loadedTiers")
        private List<Integer> loadedTiers;
    }
}