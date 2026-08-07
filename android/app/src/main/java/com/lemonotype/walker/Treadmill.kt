package com.lemonotype.walker

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

data class SessionRecord(val date: Long, val seconds: Int, val meters: Double, val steps: Int, val kcal: Double)
data class PeriodStats(var seconds: Int = 0, var meters: Double = 0.0, var steps: Int = 0)

/**
 * BLE link to the ESP32 (FTMS treadmill service) + session state:
 * ramp engine, delta-capped accumulation, goals, history, calories.
 * Mirror of the iOS TreadmillManager.
 */
@SuppressLint("MissingPermission")
object Treadmill {
    // ---- state ----
    val connected = MutableStateFlow(false)
    val speedKmh = MutableStateFlow(0.0)
    val targetKmh = MutableStateFlow(0.0)
    val distanceM = MutableStateFlow(0.0)
    val elapsedS = MutableStateFlow(0)
    val steps = MutableStateFlow(0)
    val kcal = MutableStateFlow(0.0)
    val sessionActive = MutableStateFlow(false)
    val paused = MutableStateFlow(false)
    val ramping = MutableStateFlow(false)
    val history = MutableStateFlow<List<SessionRecord>>(emptyList())
    val maintenanceDue = MutableStateFlow(false)

    const val MIN_KMH = 0.8
    const val MAX_KMH = 6.4

    private val FTMS = UUID.fromString("00001826-0000-1000-8000-00805F9B34FB")
    private val DATA = UUID.fromString("00002ACD-0000-1000-8000-00805F9B34FB")
    private val CP = UUID.fromString("00002AD9-0000-1000-8000-00805F9B34FB")
    private val STATUS = UUID.fromString("00002ADA-0000-1000-8000-00805F9B34FB")
    private val STEPS_SVC = UUID.fromString("7C9A0001-3D3A-4E7B-8A10-25C1D9E0F2A4")
    private val STEPS_CHR = UUID.fromString("7C9A0002-3D3A-4E7B-8A10-25C1D9E0F2A4")
    private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

    private lateinit var app: Context
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var gatt: BluetoothGatt? = null
    private var cpChar: BluetoothGattCharacteristic? = null
    private var rampJob: Job? = null
    private var pauseAutoEndJob: Job? = null
    private var sessionStart = 0L
    private var lastKcalUpdate = 0L
    private var lastToggle = 0L
    private var goalRampStarted = false
    private var lastFirmDist = -1.0
    private var lastFirmSteps = -1
    private var lastFirmElapsed = -1
    private val opQueue = ArrayDeque<() -> Unit>()
    private var opBusy = false

    private val prefs by lazy { app.getSharedPreferences("walker", Context.MODE_PRIVATE) }

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        loadHistory()
        checkMaintenance()
        startScan()
    }

    // ---- maintenance reminder: every 3 months OR 30 usage-hours ----
    private fun checkMaintenance() {
        var last = prefs.getLong("maintLastReset", 0L)
        if (last == 0L) {
            last = System.currentTimeMillis()
            prefs.edit().putLong("maintLastReset", last)
                .putInt("maintBaselineS", stats().seconds).apply()
        }
        val baseline = prefs.getInt("maintBaselineS", 0)
        val ageDays = (System.currentTimeMillis() - last) / 86400_000.0
        val usedHours = (stats().seconds - baseline) / 3600.0
        val due = ageDays >= 90 || usedHours >= 30
        if (due && !maintenanceDue.value) notifyMaintenanceOnce()
        maintenanceDue.value = due
    }

    fun dismissMaintenance() {
        prefs.edit().putLong("maintLastReset", System.currentTimeMillis())
            .putInt("maintBaselineS", stats().seconds)
            .putBoolean("maintNotified", false).apply()
        maintenanceDue.value = false
    }

    private fun notifyMaintenanceOnce() {
        if (prefs.getBoolean("maintNotified", false)) return
        prefs.edit().putBoolean("maintNotified", true).apply()
        try {
            val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            val ch = android.app.NotificationChannel("walker.maint", "Maintenance",
                android.app.NotificationManager.IMPORTANCE_DEFAULT)
            nm.createNotificationChannel(ch)
            val pi = android.app.PendingIntent.getActivity(app, 1,
                android.content.Intent(app, MainActivity::class.java),
                android.app.PendingIntent.FLAG_IMMUTABLE)
            nm.notify(2, android.app.Notification.Builder(app, "walker.maint")
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle("WALKER")
                .setContentText("Maintenance due: lube belt and hoover motor (3 months / 30 hours).")
                .setContentIntent(pi)
                .setAutoCancel(true)
                .build())
        } catch (_: Exception) {}
    }

    // ---- settings (SharedPreferences, written by the UI) ----
    private fun pref(key: String, def: Double) =
        prefs.getFloat(key, def.toFloat()).toDouble()
    private val startEndSpeed get() = pref("startEndSpeed", 2.0)
    private val goalSpeed get() = pref("goalSpeed", 4.0)
    private val rampMinutes get() = pref("rampMinutes", 5.0)
    private val weightKg get() = pref("weightKg", 70.0)

    // ---- scanning / connection ----
    private fun startScan() {
        val adapter = (app.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter ?: return
        if (!adapter.isEnabled) { scope.launch { delay(3000); startScan() }; return }
        val scanner = adapter.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(FTMS)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(listOf(filter), settings, scanCb)
        } catch (_: SecurityException) { /* permission not granted yet; UI retries */ }
    }

    fun retryScan() { if (::app.isInitialized && !connected.value) startScan() }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(type: Int, result: ScanResult) {
            val adapter = (app.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            try { adapter.bluetoothLeScanner?.stopScan(this) } catch (_: SecurityException) {}
            gatt = result.device.connectGatt(app, false, gattCb, BluetoothDevice.TRANSPORT_LE)
        }
    }

    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                scope.launch {
                    connected.value = false
                    cpChar = null
                    opQueue.clear(); opBusy = false
                    g.close()
                    delay(1500)
                    startScan()
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val ftms = g.getService(FTMS) ?: return
            cpChar = ftms.getCharacteristic(CP)
            listOfNotNull(
                ftms.getCharacteristic(DATA),
                ftms.getCharacteristic(STATUS),
                cpChar,
                g.getService(STEPS_SVC)?.getCharacteristic(STEPS_CHR)
            ).forEach { ch -> enqueue { subscribe(g, ch) } }
            enqueue {
                scope.launch {
                    connected.value = true
                    cp(byteArrayOf(0x00))  // request control
                }
                opDone()
            }
            pump()
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = opDone()
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = opDone()

        @Deprecated("pre-33 callback")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            val v = c.value ?: return
            scope.launch { handleNotification(c.uuid, v) }
        }
    }

    private fun subscribe(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
        g.setCharacteristicNotification(ch, true)
        val d = ch.getDescriptor(CCCD)
        if (d == null) { opDone(); return }
        val indicate = ch.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
        @Suppress("DEPRECATION")
        d.value = if (indicate) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                  else BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        @Suppress("DEPRECATION")
        g.writeDescriptor(d)
    }

    // one GATT operation at a time
    private fun enqueue(op: () -> Unit) { opQueue.addLast(op) }
    private fun pump() {
        if (opBusy) return
        val op = opQueue.removeFirstOrNull() ?: return
        opBusy = true
        op()
    }
    private fun opDone() { opBusy = false; pump() }

    // ---- control point ----
    private fun cp(bytes: ByteArray) {
        val g = gatt ?: return
        val c = cpChar ?: return
        enqueue {
            @Suppress("DEPRECATION")
            c.value = bytes
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            @Suppress("DEPRECATION")
            if (!g.writeCharacteristic(c)) opDone()
        }
        pump()
    }

    private fun sendStart() = cp(byteArrayOf(0x07))
    private fun sendStop() = cp(byteArrayOf(0x08, 0x01))
    private fun sendSpeed(kmh: Double) {
        val clamped = min(MAX_KMH, max(MIN_KMH, kmh))
        val v = (clamped * 100).toInt()
        cp(byteArrayOf(0x02, (v and 0xFF).toByte(), (v shr 8).toByte()))
        targetKmh.value = clamped
    }

    // ---- session control (mirror of iOS) ----
    fun startSession() {
        if (!connected.value || sessionActive.value) return
        sessionActive.value = true
        paused.value = false
        sessionStart = System.currentTimeMillis()
        kcal.value = 0.0
        lastFirmDist = -1.0; distanceM.value = 0.0
        lastFirmSteps = -1; steps.value = 0
        lastFirmElapsed = -1; elapsedS.value = 0
        lastKcalUpdate = System.currentTimeMillis()
        goalRampStarted = false
        sendStart()
        sendSpeed(startEndSpeed)
        startRamp(goalSpeed)
        WalkService.start(app)
    }

    fun endSession() {
        if (!sessionActive.value) return
        finishSession()
    }

    private fun finishSession() {
        rampJob?.cancel(); ramping.value = false
        pauseAutoEndJob?.cancel()
        sendStop()
        sessionActive.value = false
        paused.value = false
        recordSession()
        HealthSync.saveWorkout(app, sessionStart, System.currentTimeMillis(),
            distanceM.value, kcal.value, steps.value)
        WalkService.stop(app)
    }

    fun togglePlayPause() {
        val now = System.currentTimeMillis()
        if (now - lastToggle < 1500) return
        lastToggle = now
        if (!sessionActive.value) {
            if (connected.value) startSession()
            return
        }
        if (paused.value) {
            paused.value = false
            pauseAutoEndJob?.cancel()
            sendStart()
            val resumeTarget = if (targetKmh.value > 0) targetKmh.value else startEndSpeed
            if (resumeTarget <= startEndSpeed + 0.05) sendSpeed(resumeTarget)
            else { sendSpeed(startEndSpeed); startRamp(resumeTarget, 15.0) }
        } else {
            paused.value = true
            rampJob?.cancel(); ramping.value = false
            sendStop()
            schedulePauseAutoEnd()
        }
    }

    fun nudge(delta: Double) {
        if (!sessionActive.value || paused.value) return
        rampJob?.cancel(); ramping.value = false
        sendSpeed(targetKmh.value + delta)
    }

    private fun schedulePauseAutoEnd() {
        pauseAutoEndJob?.cancel()
        pauseAutoEndJob = scope.launch {
            delay(3600_000)
            if (sessionActive.value && paused.value) finishSession()
        }
    }

    // ---- ramp engine ----
    private fun startRamp(goal: Double, rampSeconds: Double? = null) {
        rampJob?.cancel()
        val seconds = rampSeconds ?: (rampMinutes * 60)
        val interval = min(5.0, max(1.5, seconds / 8))
        val start = targetKmh.value
        if (kotlin.math.abs(goal - start) <= 0.01 || seconds <= interval) { sendSpeed(goal); return }
        val increment = (goal - start) / (seconds / interval)
        ramping.value = true
        rampJob = scope.launch {
            while (isActive) {
                delay((interval * 1000).toLong())
                if (!sessionActive.value || paused.value) break
                var next = targetKmh.value + increment
                val reached = (increment > 0 && next >= goal) || (increment < 0 && next <= goal)
                if (reached) next = goal
                sendSpeed(kotlin.math.round(next * 100) / 100)
                if (reached) break
            }
            ramping.value = false
        }
    }

    // ---- incoming data ----
    private fun handleNotification(uuid: UUID, d: ByteArray) {
        when (uuid) {
            DATA -> parseTreadmillData(d)
            STEPS_CHR -> parseSteps(d)
            STATUS -> {
                val s = d.firstOrNull()?.toInt() ?: return
                if ((s == 0x02 || s == 0x03) && sessionActive.value && !paused.value) {
                    paused.value = true
                    rampJob?.cancel(); ramping.value = false
                    schedulePauseAutoEnd()
                }
            }
        }
        if (sessionActive.value) WalkService.refresh(app)
    }

    private fun u16(d: ByteArray, i: Int) = (d[i].toInt() and 0xFF) or ((d[i + 1].toInt() and 0xFF) shl 8)

    private fun parseTreadmillData(d: ByteArray) {
        if (d.size < 4) return
        val flags = u16(d, 0)
        var i = 2
        speedKmh.value = u16(d, i) / 100.0
        i += 2
        if (flags and 0x0004 != 0 && d.size >= i + 3) {
            val dist = (u16(d, i) or ((d[i + 2].toInt() and 0xFF) shl 16)).toDouble()
            if (sessionActive.value && !paused.value && lastFirmDist >= 0) {
                val delta = dist - lastFirmDist
                if (delta > 0 && delta < 10) distanceM.value += delta
            }
            lastFirmDist = dist
            i += 3
        }
        if (flags and 0x0400 != 0 && d.size >= i + 2) {
            val el = u16(d, i)
            if (sessionActive.value && !paused.value && lastFirmElapsed >= 0) {
                val delta = el - lastFirmElapsed
                if (delta in 1..5) elapsedS.value += delta
            }
            lastFirmElapsed = el
            i += 2
        }
        if (sessionActive.value && !paused.value) {
            val dtMin = (System.currentTimeMillis() - lastKcalUpdate) / 60000.0
            if (dtMin > 0 && dtMin < 1) {
                val met = max(1.2, 0.9 + 0.5 * speedKmh.value)
                kcal.value += met * 3.5 * weightKg / 200 * dtMin
            }
            checkGoal()
        }
        lastKcalUpdate = System.currentTimeMillis()
    }

    private fun parseSteps(d: ByteArray) {
        if (d.size < 4) return
        val s = u16(d, 0) or (u16(d, 2) shl 16)
        if (sessionActive.value && !paused.value && lastFirmSteps >= 0) {
            val delta = s - lastFirmSteps
            if (delta in 1..10) steps.value += delta
        }
        lastFirmSteps = s
    }

    // ---- session goal ----
    private fun checkGoal() {
        val type = prefs.getString("goalType", "none") ?: "none"
        if (type == "none") return
        val remainingMin: Double = when (type) {
            "time" -> {
                val g = pref("goalTimeMin", 30.0); if (g <= 0) return
                (g * 60 - elapsedS.value) / 60
            }
            "km" -> {
                val g = pref("goalKm", 2.0); if (g <= 0) return
                val mps = max(speedKmh.value / 3.6, 0.15)
                (g * 1000 - distanceM.value) / mps / 60
            }
            "steps" -> {
                val g = pref("goalSteps", 3000.0); if (g <= 0) return
                val rate = if (elapsedS.value > 120) steps.value / (elapsedS.value / 60.0) else 100.0
                (g - steps.value) / max(rate, 30.0)
            }
            else -> return
        }
        if (remainingMin <= 0) {
            finishSession()
        } else if (remainingMin <= 2 && !goalRampStarted) {
            goalRampStarted = true
            startRamp(startEndSpeed, max(remainingMin * 60 - 10, 30.0))
        }
    }

    // ---- history ----
    fun stats(sinceMs: Long? = null, untilMs: Long? = null): PeriodStats {
        val s = PeriodStats()
        for (r in history.value) {
            if (sinceMs != null && r.date < sinceMs) continue
            if (untilMs != null && r.date >= untilMs) continue
            s.seconds += r.seconds; s.meters += r.meters; s.steps += r.steps
        }
        return s
    }

    private fun recordSession() {
        if (elapsedS.value <= 30) return
        val list = history.value + SessionRecord(
            System.currentTimeMillis(), elapsedS.value, distanceM.value, steps.value, kcal.value)
        history.value = list
        val arr = JSONArray()
        list.forEach {
            arr.put(JSONObject()
                .put("date", it.date).put("seconds", it.seconds)
                .put("meters", it.meters).put("steps", it.steps).put("kcal", it.kcal))
        }
        prefs.edit().putString("sessionHistory", arr.toString()).apply()
        checkMaintenance()
    }

    private fun loadHistory() {
        val raw = prefs.getString("sessionHistory", null) ?: return
        try {
            val arr = JSONArray(raw)
            history.value = (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                SessionRecord(o.getLong("date"), o.getInt("seconds"),
                    o.getDouble("meters"), o.getInt("steps"), o.getDouble("kcal"))
            }
        } catch (_: Exception) {}
    }
}
