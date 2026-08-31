package com.neganote.reportingservice.repository;

import com.neganote.reportingservice.entity.ReportingLog;
import org.springframework.data.jpa.repository.JpaRepository;

public interface ReportingLogRepository extends JpaRepository<ReportingLog, Long> {
    boolean existsByEventId(String eventId);
}
