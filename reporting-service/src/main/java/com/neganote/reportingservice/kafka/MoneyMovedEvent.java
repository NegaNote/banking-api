package com.neganote.reportingservice.kafka;

import java.math.BigDecimal;
import java.time.Instant;

public record MoneyMovedEvent(
        String eventId, // UUID - immutable, for idempotency
        String eventType,
        Long userId,
        String accountNumber,
        String counterpartyAccountNumber, // null for deposit/withdrawal
        BigDecimal amount,
        String result, // SUCCESS, DECLINED
        String requestId,
        String traceId,
        Instant occurredAt) {}
