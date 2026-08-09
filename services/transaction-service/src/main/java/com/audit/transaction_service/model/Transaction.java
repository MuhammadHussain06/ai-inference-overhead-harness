package com.audit.transaction_service.model;

import org.springframework.data.annotation.Id;
import org.springframework.data.relational.core.mapping.Column;
import org.springframework.data.relational.core.mapping.Table;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Table("transactions")
public class Transaction {

    @Id
    private Long primaryId;

    @Column("transaction_id")
    private String transactionId;

    @Column("account_id")
    private String accountId;

    @Column("transaction_amount")
    private BigDecimal transactionAmount;

    @Column("transaction_type")
    private String transactionType;

    @Column("evaluation_strategy")
    private String evaluationStrategy;

    @Column("execution_time_ms")
    private double executionTimeMs;

    @Column("transaction_status")
    private String transactionStatus;

    @Column("risk_score")
    private Double riskScore;

    @Column("created_at")
    private LocalDateTime createdAt = LocalDateTime.now();

    private double v1;
    private double v2;
    private double v3;
    private double v4;
    private double v5;

    public Transaction() {}

    public Long getPrimaryId() { return primaryId; }
    public void setPrimaryId(Long primaryId) { this.primaryId = primaryId; }
    public String getTransactionId() { return transactionId; }
    public void setTransactionId(String transactionId) { this.transactionId = transactionId; }
    public String getAccountId() { return accountId; }
    public void setAccountId(String accountId) { this.accountId = accountId; }
    public BigDecimal getTransactionAmount() { return transactionAmount; }
    public void setTransactionAmount(BigDecimal transactionAmount) { this.transactionAmount = transactionAmount; }
    public String getTransactionType() { return transactionType; }
    public void setTransactionType(String transactionType) { this.transactionType = transactionType; }
    public String getEvaluationStrategy() { return evaluationStrategy; }
    public void setEvaluationStrategy(String evaluationStrategy) { this.evaluationStrategy = evaluationStrategy; }
    public double getExecutionTimeMs() { return executionTimeMs; }
    public void setExecutionTimeMs(double executionTimeMs) { this.executionTimeMs = executionTimeMs; }
    public String getTransactionStatus() { return transactionStatus; }
    public void setTransactionStatus(String transactionStatus) { this.transactionStatus = transactionStatus; }
    public Double getRiskScore() { return riskScore; }
    public void setRiskScore(Double riskScore) { this.riskScore = riskScore; }
    public LocalDateTime getCreatedAt() { return createdAt; }
    public void setCreatedAt(LocalDateTime createdAt) { this.createdAt = createdAt; }
    public double getV1() { return v1; }
    public void setV1(double v1) { this.v1 = v1; }
    public double getV2() { return v2; }
    public void setV2(double v2) { this.v2 = v2; }
    public double getV3() { return v3; }
    public void setV3(double v3) { this.v3 = v3; }
    public double getV4() { return v4; }
    public void setV4(double v4) { this.v4 = v4; }
    public double getV5() { return v5; }
    public void setV5(double v5) { this.v5 = v5; }
}
