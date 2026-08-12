package com.audit.transaction_service.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.math.BigDecimal;
import java.util.List;

public class RequestDto {

    @NotNull(message = "transactionId is required")
    @Pattern(
            regexp = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            message = "transactionId must be a valid UUID format"
    )
    private String transactionId;

    @NotNull(message = "accountId is required")
    @Pattern(
            regexp = "^ACC-\\d{4,10}$",
            message = "accountId must follow format 'ACC-XXXX'"
    )
    private String accountId;

    @NotNull(message = "amount is required")
    private BigDecimal amount;

    @NotNull(message = "transactionType is required")
    private String transactionType;

    @NotNull(message = "features is required")
    private List<Double> features;


    @NotNull(message = "strategy is required")
    private String strategy;

    // Feature-count tier for the AI strategy: one of 5, 10, 20, 28.
    // Ignored for DISTRIBUTED_MOCK_GATEWAY.
    private Integer featureTier;

    public RequestDto() {}

    public String getTransactionId() { return transactionId; }
    public void setTransactionId(String transactionId) { this.transactionId = transactionId; }

    public String getAccountId() { return accountId; }
    public void setAccountId(String accountId) { this.accountId = accountId; }

    public BigDecimal getAmount() { return amount; }
    public void setAmount(BigDecimal amount) { this.amount = amount; }

    public String getTransactionType() { return transactionType; }
    public void setTransactionType(String transactionType) { this.transactionType = transactionType; }

    public List<Double> getFeatures() { return features; }
    public void setFeatures(List<Double> features) { this.features = features; }

    public String getStrategy() { return strategy; }
    public void setStrategy(String strategy) { this.strategy = strategy; }

    public Integer getFeatureTier() { return featureTier; }
    public void setFeatureTier(Integer featureTier) { this.featureTier = featureTier; }
}
