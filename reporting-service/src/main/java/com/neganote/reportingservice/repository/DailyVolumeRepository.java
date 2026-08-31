package com.neganote.reportingservice.repository;

import com.neganote.reportingservice.entity.DailyVolume;
import org.springframework.data.jpa.repository.JpaRepository;

import java.time.LocalDate;
import java.util.Optional;

public interface DailyVolumeRepository extends JpaRepository<DailyVolume, Long> {
    Optional<DailyVolume> findByDayAndEventType(LocalDate day, String eventType);
}
