package com.lemonotype.walker

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.*
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneOffset

/** Writes finished sessions to Health Connect (if installed & permitted). */
object HealthSync {
    val permissions = setOf(
        HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        HealthPermission.getWritePermission(StepsRecord::class),
        HealthPermission.getWritePermission(DistanceRecord::class),
        HealthPermission.getWritePermission(TotalCaloriesBurnedRecord::class),
    )

    fun available(ctx: Context) =
        HealthConnectClient.getSdkStatus(ctx) == HealthConnectClient.SDK_AVAILABLE

    fun saveWorkout(ctx: Context, startMs: Long, endMs: Long,
                    meters: Double, kcal: Double, steps: Int) {
        if (!available(ctx)) return
        if (endMs - startMs < 30_000) return
        val client = HealthConnectClient.getOrCreate(ctx)
        val start = Instant.ofEpochMilli(startMs)
        val end = Instant.ofEpochMilli(endMs)
        val zone = ZoneOffset.systemDefault().rules.getOffset(start)
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val records = mutableListOf<androidx.health.connect.client.records.Record>(
                    ExerciseSessionRecord(
                        startTime = start, startZoneOffset = zone,
                        endTime = end, endZoneOffset = zone,
                        exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
                        title = "Treadmill walk",
                    )
                )
                if (steps > 0) records.add(StepsRecord(
                    startTime = start, startZoneOffset = zone,
                    endTime = end, endZoneOffset = zone, count = steps.toLong()))
                if (meters > 1) records.add(DistanceRecord(
                    startTime = start, startZoneOffset = zone,
                    endTime = end, endZoneOffset = zone,
                    distance = Length.meters(meters)))
                if (kcal > 1) records.add(TotalCaloriesBurnedRecord(
                    startTime = start, startZoneOffset = zone,
                    endTime = end, endZoneOffset = zone,
                    energy = Energy.kilocalories(kcal)))
                client.insertRecords(records)
            } catch (_: Exception) { /* no permission / HC missing: skip */ }
        }
    }
}
