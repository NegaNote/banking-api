CREATE TABLE daily_volumes (
    id BIGINT NOT NULL AUTO_INCREMENT,
    day DATE NOT NULL,
    event_type VARCHAR(20) NOT NULL,
    total_volume DECIMAL(14,2) NOT NULL DEFAULT 0.00,
    daily_count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY uk_daily_volumes_day_event_type (day, event_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
