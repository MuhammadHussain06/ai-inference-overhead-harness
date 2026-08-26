package com.audit.transaction_service.config;

import io.netty.channel.ChannelOption;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;
import reactor.netty.resources.ConnectionProvider;

import java.time.Duration;

@Slf4j
@Configuration
public class WebClientConfig {

    @Value("${python.service.url:http://python:8000}")
    private String pythonServiceUrl;

    @Value("${python.service.connect-timeout-ms:2000}")
    private int connectTimeoutMs;

    @Value("${python.service.response-timeout-ms:5000}")
    private long responseTimeoutMs;

    // Must stay >= the highest VUS in run-suite.sh's CONCURRENCY_LEVELS
    // (currently 64), or outbound queueing here inflates aiCallRoundTripTimeMs /
    // estimatedNetworkOverheadMs indistinguishably from real network/Python cost.
    @Value("${python.service.max-connections:128}")
    private int maxConnections;

    // Bounds how long a request waits for a pooled connection, so pool
    // exhaustion fails fast instead of silently inflating round-trip time.
    @Value("${python.service.pending-acquire-timeout-ms:5000}")
    private long pendingAcquireTimeoutMs;

    @Bean
    public WebClient webClient(WebClient.Builder builder) {
        ConnectionProvider connectionProvider = ConnectionProvider.builder("python-service-pool")
                .maxConnections(maxConnections)
                .pendingAcquireTimeout(Duration.ofMillis(pendingAcquireTimeoutMs))
                .build();

        log.info("[WebClientConfig] python-service outbound pool: maxConnections={} pendingAcquireTimeoutMs={}",
                maxConnections, pendingAcquireTimeoutMs);

        HttpClient httpClient = HttpClient.create(connectionProvider)
                .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, connectTimeoutMs)
                .responseTimeout(Duration.ofMillis(responseTimeoutMs));

        return builder
                .baseUrl(pythonServiceUrl)
                .clientConnector(new ReactorClientHttpConnector(httpClient))
                .defaultHeader("Content-Type", "application/json")
                .build();
    }
}