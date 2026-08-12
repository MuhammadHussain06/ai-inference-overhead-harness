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

    @Column("feature_tier")
    private Integer featureTier;

    @Column("features_csv")
    private String featuresCsv;

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
    public Integer getFeatureTier() { return featureTier; }
    public void setFeatureTier(Integer featureTier) { this.featureTier = featureTier; }
    public String getFeaturesCsv() { return featuresCsv; }
    public void setFeaturesCsv(String featuresCsv) { this.featuresCsv = featuresCsv; }
}
