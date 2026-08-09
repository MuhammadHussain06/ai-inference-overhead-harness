package com.audit.transaction_service.repository;

import com.audit.transaction_service.model.Transaction;
import org.springframework.data.repository.reactive.ReactiveCrudRepository;
import org.springframework.stereotype.Repository;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

@Repository
public interface TransactionRepository extends ReactiveCrudRepository<Transaction, Long> {
    Flux<Transaction> findByAccountId(String accountId);
    Flux<Transaction> findByEvaluationStrategy(String evaluationStrategy);
    Mono<Transaction> findByTransactionId(String transactionId);
}
