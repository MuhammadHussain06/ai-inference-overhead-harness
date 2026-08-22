package com.audit.transaction_service.dto;

import java.util.List;

public class AiRequestDto {

    private String transactionId;

    private double amount;

    private List<Double> features;

    public AiRequestDto() {}

    public AiRequestDto(String transactionId, double amount, List<Double> features) {
        this.transactionId = transactionId;
        this.amount = amount;
        this.features = features;
    }

    public String getTransactionId() {
        return transactionId;
    }
    public void setTransactionId(String transactionId) {
        this.transactionId = transactionId;
    }

    public double getAmount() {
        return amount;
    }
    public void setAmount(double amount) {
        this.amount = amount;
    }

    public List<Double> getFeatures() {
        return features;
    }
    public void setFeatures(List<Double> features) {
        this.features = features;
    }
}