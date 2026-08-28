package com.neganote.notificationservice.kafka;

import com.neganote.notificationservice.entity.NotificationLog;
import com.neganote.notificationservice.repository.NotificationLogRepository;
import lombok.RequiredArgsConstructor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
public class MoneyMovedEventListener {

    private final NotificationLogRepository notificationLogRepository;

    private static Logger logger = LoggerFactory.getLogger(MoneyMovedEventListener.class);

    @KafkaListener(topics = "banking.money-movements", groupId = "notifications", concurrency = "3")
    public void onEvent(MoneyMovedEvent event) {
        if (notificationLogRepository.existsByEventId(event.eventId())) {
            logger.info("Skipping duplicate event {}", event.eventId());
            return;
        }
        if ("SUCCESS".equals(event.result())) {
            logger.info("NOTIFICATION: user={} amount={} eventType={} — sent via SMS (simulated)",
                    event.userId(), event.amount(), event.eventType());
        }
        notificationLogRepository.save(NotificationLog.builder()
                        .eventId(event.eventId())
                        .eventType(event.eventType())
                        .amount(event.amount())
                .build());
    }
}
