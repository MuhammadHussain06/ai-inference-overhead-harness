package com.audit.transaction_service.filter;

import org.junit.jupiter.api.Test;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.AnnotationUtils;
import org.springframework.core.annotation.Order;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The request-start stamp anchors every Java-side latency figure, so it must be
 * written before any other filter and must be a usable monotonic reading.
 */
class RequestTimingWebFilterTest {

    private static final RequestTimingWebFilter FILTER = new RequestTimingWebFilter();

    private static ServerWebExchange filteredExchange() {
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.post("/api/v1/transactions").build());
        FILTER.filter(exchange, ignored -> Mono.empty()).block();
        return exchange;
    }

    private static Long stampOf(ServerWebExchange exchange) {
        return (Long) exchange.getAttributes().get(RequestTimingWebFilter.REQUEST_START_NANOS_ATTR);
    }

    @Test
    void stampsRequestStartNanosOnTheExchange() {
        assertThat(stampOf(filteredExchange())).isNotNull();
    }

    @Test
    void stampIsTakenBeforeTheChainCompletes() {
        long before = System.nanoTime();
        Long stamp = stampOf(filteredExchange());
        long after = System.nanoTime();

        assertThat(stamp).isBetween(before, after);
    }

    @Test
    void separateRequestsGetDistinctIncreasingStamps() {
        Long first = stampOf(filteredExchange());
        Long second = stampOf(filteredExchange());

        assertThat(second).isGreaterThan(first);
    }

    @Test
    void runsAtHighestPrecedenceSoNoFilterCanPrecedeIt() {
        Order order = AnnotationUtils.findAnnotation(RequestTimingWebFilter.class, Order.class);

        assertThat(order).isNotNull();
        assertThat(order.value()).isEqualTo(Ordered.HIGHEST_PRECEDENCE);
    }

    @Test
    void delegatesToTheRestOfTheChain() {
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.post("/api/v1/transactions").build());
        boolean[] chainRan = {false};

        FILTER.filter(exchange, ignored -> Mono.fromRunnable(() -> chainRan[0] = true)).block();

        assertThat(chainRan[0]).isTrue();
    }
}