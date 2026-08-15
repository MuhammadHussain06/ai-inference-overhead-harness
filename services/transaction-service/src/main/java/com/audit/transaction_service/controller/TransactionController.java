package com.audit.transaction_service.controller;

import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.filter.RequestTimingWebFilter;
import com.audit.transaction_service.service.TransactionService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

@RestController
@RequestMapping("/api/v1/transactions")
public class TransactionController {

    private final TransactionService transactionService;

    public TransactionController(TransactionService transactionService) {
        this.transactionService = transactionService;
    }

    @PostMapping
    public Mono<ResponseEntity<ResponseDto>> processTransaction(@Valid @RequestBody RequestDto request,ServerWebExchange exchange) {
        long requestStartNanos = (long) exchange.getAttributeOrDefault(
                RequestTimingWebFilter.REQUEST_START_NANOS_ATTR, System.nanoTime());
        return transactionService.processTransaction(request, requestStartNanos)
                .map(ResponseEntity::ok);
    }
}