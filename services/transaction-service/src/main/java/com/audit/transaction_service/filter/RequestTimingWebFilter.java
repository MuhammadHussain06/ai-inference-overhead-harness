package com.audit.transaction_service.filter;

import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestTimingWebFilter implements WebFilter {

    public static final String REQUEST_START_NANOS_ATTR = "requestStartNanos";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        exchange.getAttributes().put(REQUEST_START_NANOS_ATTR, System.nanoTime());
        return chain.filter(exchange);
    }
}