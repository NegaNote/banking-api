package com.neganote.reportingservice.entity;

import jakarta.persistence.*;
import lombok.*;

import java.time.Instant;

@Entity
@Table(name = "reporting_logs", uniqueConstraints = {@UniqueConstraint(columnNames = "event_id")})
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class ReportingLog {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "event_id", nullable = false, length = 40)
    private String eventId;

    @Column(name = "reported_at", nullable = false)
    private Instant reportedAt;
}
