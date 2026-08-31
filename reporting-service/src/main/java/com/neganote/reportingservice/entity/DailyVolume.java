package com.neganote.reportingservice.entity;

import jakarta.persistence.*;
import lombok.*;

import java.math.BigDecimal;
import java.time.LocalDate;

@Entity
@Table(name = "daily_volumes", uniqueConstraints = {@UniqueConstraint(columnNames = {"day", "event_type"})})
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class DailyVolume {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "day", nullable = false)
    private LocalDate day;

    @Column(name = "event_type", nullable = false, length = 20)
    private String eventType;

    @Column(name = "total_volume", nullable = false, precision = 14, scale = 2)
    private BigDecimal totalVolume = BigDecimal.ZERO;

    @Column(name = "daily_count", nullable = false)
    private int count = 0;
}
