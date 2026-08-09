package com.audit.transaction_service.controller;

import com.audit.transaction_service.dto.RequestDto;
import com.audit.transaction_service.dto.ResponseDto;
import com.audit.transaction_service.service.TransactionService;
import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Mono;

@RestController
@RequestMapping("/api/v1/transactions")
public class TransactionController {

    private final TransactionService transactionService;

    public TransactionController(TransactionService transactionService) {
        this.transactionService = transactionService;
    }

    @PostMapping
    public Mono<ResponseEntity<ResponseDto>> processTransaction(@Valid @RequestBody RequestDto request) {
        return transactionService.processTransaction(request)
                .map(ResponseEntity::ok);
    }
}
