package com.neganote.notificationservice.repository;

import com.neganote.notificationservice.entity.NotificationLog;
import org.springframework.data.jpa.repository.JpaRepository;

public interface NotificationLogRepository extends JpaRepository<NotificationLog, Long> {
    boolean existsByEventId(String eventId);
}
