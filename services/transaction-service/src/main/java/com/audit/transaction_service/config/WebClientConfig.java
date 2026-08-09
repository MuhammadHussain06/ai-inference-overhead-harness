package com.audit.transaction_service.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.reactive.function.client.WebClient;

@Configuration
public class WebClientConfig {

    @Value("${python.service.url:http://python:8000}")
    private String pythonServiceUrl;

    @Bean
    public WebClient webClient(WebClient.Builder builder) {
        return builder
                .baseUrl(pythonServiceUrl)
                .defaultHeader("Content-Type", "application/json")
                .build();
    }
}
