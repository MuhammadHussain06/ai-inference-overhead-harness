package com.audit.transaction_service.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.math.BigDecimal;

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

    private double v1;
    private double v2;
    private double v3;
    private double v4;
    private double v5;

    // Academic topology strategy toggle: DISTRIBUTED_AI_SYNCHRONOUS | DISTRIBUTED_MOCK_GATEWAY
    @NotNull(message = "strategy is required")
    private String strategy;

    public RequestDto() {}

    public String getTransactionId() { return transactionId; }
    public void setTransactionId(String transactionId) { this.transactionId = transactionId; }

    public String getAccountId() { return accountId; }
    public void setAccountId(String accountId) { this.accountId = accountId; }

    public BigDecimal getAmount() { return amount; }
    public void setAmount(BigDecimal amount) { this.amount = amount; }

    public String getTransactionType() { return transactionType; }
    public void setTransactionType(String transactionType) { this.transactionType = transactionType; }

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

    public String getStrategy() { return strategy; }
    public void setStrategy(String strategy) { this.strategy = strategy; }
}
