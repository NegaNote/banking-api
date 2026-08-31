CREATE TABLE reporting_logs (
    id BIGINT NOT NULL AUTO_INCREMENT,
    event_id VARCHAR(40) NOT NULL,
    reported_at DATETIME(6) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_reporting_logs_event_id (event_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
