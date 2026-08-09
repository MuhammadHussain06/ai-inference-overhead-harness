CREATE TABLE IF NOT EXISTS transactions (
    primary_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(255),
    account_id VARCHAR(255),
    transaction_amount DECIMAL(19, 4),
    transaction_type VARCHAR(255),
    evaluation_strategy VARCHAR(255),
    execution_time_ms DOUBLE,
    transaction_status VARCHAR(255),
    risk_score DOUBLE,
    created_at TIMESTAMP,
    v1 DOUBLE,
    v2 DOUBLE,
    v3 DOUBLE,
    v4 DOUBLE,
    v5 DOUBLE
    );
