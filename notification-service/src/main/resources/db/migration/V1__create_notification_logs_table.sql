CREATE TABLE notification_logs (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    event_id VARCHAR(40) NOT NULL,
    event_type VARCHAR(20) NOT NULL,
    amount DECIMAL(14,2) NOT NULL,
    occurred_at DATETIME(6) NOT NULL
) engine=InnoDB DEFAULT CHARSET=utf8mb4;