package com.neganote.reportingservice.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.neganote.reportingservice.entity.DailyVolume;
import com.neganote.reportingservice.entity.ReportingLog;
import com.neganote.reportingservice.repository.DailyVolumeRepository;
import com.neganote.reportingservice.repository.ReportingLogRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;

@Component
@RequiredArgsConstructor
public class MoneyMovedEventListener {

    private final ReportingLogRepository reportingLogRepository;
    private final DailyVolumeRepository volumeRepository;
    private final ObjectMapper objectMapper;

    @KafkaListener(topics = "banking.money-movements", groupId = "reporting")
    public void onEvent(String messageJson) {
        try {
            MoneyMovedEvent event = objectMapper.readValue(messageJson, MoneyMovedEvent.class);

            if (reportingLogRepository.existsByEventId(event.eventId())) return;   // idempotent

            LocalDate day = event.occurredAt().atZone(ZoneOffset.UTC).toLocalDate();
            DailyVolume volume = volumeRepository
                    .findByDayAndEventType(day, event.eventType())
                    .orElseGet(() -> DailyVolume.builder().day(day).eventType(event.eventType()).totalVolume(BigDecimal.ZERO).count(0).build());
            volume.setTotalVolume(volume.getTotalVolume().add(event.amount()));
            volume.setCount(volume.getCount() + 1);
            volumeRepository.save(volume);
            reportingLogRepository.save(ReportingLog.builder().eventId(event.eventId()).reportedAt(Instant.now()).build());
        } catch (Exception e) {
            throw new RuntimeException("Failed to process event", e);
        }

    }
}
