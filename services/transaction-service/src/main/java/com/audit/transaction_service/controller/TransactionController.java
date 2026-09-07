package com.audit.transaction_service.controller;

import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.filter.RequestTimingWebFilter;
import com.audit.transaction_service.service.TransactionService;
import jakarta.validation.Valid;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

@Slf4j
@RestController
@RequestMapping("/api/v1/transactions")
public class TransactionController {

    private final TransactionService transactionService;

    public TransactionController(TransactionService transactionService) {
        this.transactionService = transactionService;
    }

    @PostMapping
    public Mono<ResponseEntity<ResponseDto>> processTransaction(@Valid @RequestBody RequestDto request,
                                                                ServerWebExchange exchange) {
        // Reads the filter's stamp rather than taking a new one, so executionTimeMs
        // covers WebFlux dispatch, body decode and bean validation.
        Long stamp = exchange.getAttribute(RequestTimingWebFilter.REQUEST_START_NANOS_ATTR);
        long requestStartNanos;
        if (stamp != null) {
            requestStartNanos = stamp;
        } else {
            // Only reachable if the filter did not run. Falling back silently would
            // understate every Java-side figure by the whole framework-ingress term.
            requestStartNanos = System.nanoTime();
            log.warn("[{}] RequestTimingWebFilter did not stamp this exchange; timings for this "
                    + "request exclude framework ingress.", request.getTransactionId());
        }
        return transactionService.processTransaction(request, requestStartNanos)
                .map(ResponseEntity::ok);
    }
}