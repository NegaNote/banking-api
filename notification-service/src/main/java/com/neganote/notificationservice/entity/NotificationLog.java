package com.neganote.notificationservice.entity;

import jakarta.persistence.*;
import lombok.*;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneId;

@Entity
@Table(name = "notification_logs", uniqueConstraints = {@UniqueConstraint(columnNames = "event_id")})
@NoArgsConstructor
@AllArgsConstructor
@Getter
@Setter
@Builder
public class NotificationLog {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "event_id", nullable = false, length = 40)
    private String eventId;

    @Column(name = "event_type", nullable = false, length = 20)
    private String eventType;

    @Column(name = "amount", precision = 14, scale = 2, nullable = false)
    private BigDecimal amount;

    @Column(name = "occurred_at", nullable = false)
    private LocalDateTime occurredAt;

    @PrePersist
    public void onCreate() {
        this.occurredAt = LocalDateTime.now(ZoneId.of("UTC"));
    }
}
