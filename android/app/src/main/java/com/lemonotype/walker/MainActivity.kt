package com.lemonotype.walker

import android.Manifest
import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.PermissionController

val Lime = Color(0xFFD6FF00)
val Red = Color(0xFFFF3B30)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Treadmill.init(this)
        setContent { WalkerApp() }
    }
}

private fun prefs(ctx: Context) = ctx.getSharedPreferences("walker", Context.MODE_PRIVATE)

@Composable
fun WalkerApp() {
    val ctx = androidx.compose.ui.platform.LocalContext.current

    val blePerms = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { Treadmill.retryScan() }
    val healthPerms = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract()
    ) {}
    LaunchedEffect(Unit) {
        blePerms.launch(arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.POST_NOTIFICATIONS))
    }

    val connected by Treadmill.connected.collectAsState()
    val speed by Treadmill.speedKmh.collectAsState()
    val target by Treadmill.targetKmh.collectAsState()
    val dist by Treadmill.distanceM.collectAsState()
    val elapsed by Treadmill.elapsedS.collectAsState()
    val steps by Treadmill.steps.collectAsState()
    val kcal by Treadmill.kcal.collectAsState()
    val active by Treadmill.sessionActive.collectAsState()
    val paused by Treadmill.paused.collectAsState()
    val ramping by Treadmill.ramping.collectAsState()
    @Suppress("UNUSED_VARIABLE") val hist by Treadmill.history.collectAsState()

    var showSettings by remember { mutableStateOf(false) }
    var useMiles by remember { mutableStateOf(prefs(ctx).getBoolean("useMiles", false)) }
    val maintDue by Treadmill.maintenanceDue.collectAsState()

    fun cv(kmh: Double) = if (useMiles) kmh / 1.609344 else kmh
    fun dcv(m: Double) = if (useMiles) m / 1609.344 else m / 1000
    val unit = if (useMiles) "MPH" else "KM/H"
    val distUnit = if (useMiles) "MI" else "KM"

    MaterialTheme(colorScheme = darkColorScheme(background = Color.Black)) {
        Column(
            Modifier.fillMaxSize().background(Color.Black)
                .padding(16.dp).padding(top = 24.dp)
        ) {
            // header
            Row(verticalAlignment = Alignment.CenterVertically) {
                Mono("WALKER", 18.sp, FontWeight.Black)
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(12.dp).background(if (connected) Lime else Red))
                Spacer(Modifier.width(6.dp))
                Mono(if (connected) "LINK" else "SCAN", 11.sp, FontWeight.Bold, Color.Gray)
                Spacer(Modifier.width(10.dp))
                Box(Modifier.border(2.dp, Color.White).clickable { showSettings = true }
                    .padding(horizontal = 8.dp, vertical = 5.dp)) {
                    Mono("SETTINGS", 12.sp, FontWeight.Black)
                }
            }

            if (maintDue) {
                Spacer(Modifier.height(10.dp))
                Row(
                    Modifier.fillMaxWidth().background(Color(0xFFFFB800)).padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Mono("⚠ MAINTENANCE — LUBE BELT AND HOOVER MOTOR", 10.sp, FontWeight.Black, Color.Black)
                    Spacer(Modifier.weight(1f))
                    Box(Modifier.border(2.dp, Color.Black)
                        .clickable { Treadmill.dismissMaintenance() }
                        .padding(horizontal = 8.dp, vertical = 3.dp)) {
                        Mono("X", 12.sp, FontWeight.Black, Color.Black)
                    }
                }
            }

            Spacer(Modifier.weight(1f))

            // target speed
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Mono("%.1f".format(cv(if (active) target else 0.0)), 80.sp, FontWeight.Black,
                    if (active && !paused) Lime else Color.White)
                Row {
                    Mono(unit, 13.sp, FontWeight.Bold)
                    if (paused) Mono("  · PAUSED", 13.sp, FontWeight.Bold, Red)
                    else if (ramping) Mono("  · RAMP", 13.sp, FontWeight.Bold, Lime)
                    Mono("  · BELT %.1f".format(cv(speed)), 13.sp, FontWeight.Bold, Color.Gray)
                }
            }

            Spacer(Modifier.weight(1f))

            // session grid
            val timeText = if (elapsed >= 3600) "%d:%02d:%02d".format(elapsed / 3600, elapsed / 60 % 60, elapsed % 60)
                           else "%02d:%02d".format(elapsed / 60, elapsed % 60)
            Column(Modifier.border(2.dp, Color.White)) {
                Row {
                    BigCell("TIME", timeText, Modifier.weight(1f))
                    VLine(2.dp, Color.White)
                    BigCell("DIST", "%.2f %s".format(dcv(dist), distUnit), Modifier.weight(1f))
                }
                HLine(2.dp, Color.White)
                Row {
                    BigCell("STEPS", "$steps", Modifier.weight(1f))
                    VLine(2.dp, Color.White)
                    BigCell("KCAL", "%.0f".format(kcal), Modifier.weight(1f))
                }
            }

            Spacer(Modifier.height(10.dp))

            // lifetime + 30-day rows
            val total = Treadmill.stats()
            val now = System.currentTimeMillis()
            val last = Treadmill.stats(sinceMs = now - 30L * 86400_000)
            val prev = Treadmill.stats(sinceMs = now - 60L * 86400_000, untilMs = now - 30L * 86400_000)
            fun dur(s: Int) = if (s >= 3600) "%dH%02d".format(s / 3600, s / 60 % 60) else "%dM".format(s / 60)
            fun sgn(v: Double, f: String) = (if (v >= 0) "+" else "") + f.format(v)

            Row(Modifier.border(1.dp, Color.Gray)) {
                SmallCell("Σ TIME", dur(total.seconds), Modifier.weight(1f))
                VLine(1.dp, Color.Gray)
                SmallCell("Σ $distUnit", "%.1f".format(dcv(total.meters)), Modifier.weight(1f))
                VLine(1.dp, Color.Gray)
                SmallCell("Σ STEPS", "${total.steps}", Modifier.weight(1f))
            }
            Spacer(Modifier.height(8.dp))
            Row(Modifier.border(1.dp, Color.Gray)) {
                SmallCell("30D TIME", "${dur(last.seconds)} (${sgn((last.seconds - prev.seconds) / 60.0, "%.0fM")})", Modifier.weight(1f))
                VLine(1.dp, Color.Gray)
                SmallCell("30D $distUnit", "%.1f (%s)".format(dcv(last.meters), sgn(dcv(last.meters - prev.meters), "%.1f")), Modifier.weight(1f))
                VLine(1.dp, Color.Gray)
                SmallCell("30D STEPS", "${last.steps} (${sgn((last.steps - prev.steps).toDouble(), "%.0f")})", Modifier.weight(1f))
            }

            Spacer(Modifier.weight(1f))

            // nudges
            Row {
                NudgeButton("−0.1", active && !paused, Modifier.weight(1f)) { Treadmill.nudge(-0.1) }
                Spacer(Modifier.width(12.dp))
                NudgeButton("+0.1", active && !paused, Modifier.weight(1f)) { Treadmill.nudge(+0.1) }
            }
            Spacer(Modifier.height(10.dp))

            // main controls
            if (!active) {
                BigButton("START", Lime, connected) {
                    Treadmill.startSession()
                    if (HealthSync.available(ctx)) healthPerms.launch(HealthSync.permissions)
                }
            } else {
                Row {
                    BigButton(if (paused) "RESUME" else "PAUSE", Color.White, true,
                        Modifier.weight(1f)) { Treadmill.togglePlayPause() }
                    Spacer(Modifier.width(12.dp))
                    BigButton("END", Red, true, Modifier.weight(1f)) { Treadmill.endSession() }
                }
            }
        }

        if (showSettings) {
            SettingsSheet(useMiles,
                onUnits = { useMiles = it; prefs(ctx).edit().putBoolean("useMiles", it).apply() },
                onClose = { showSettings = false })
        }
    }
}

@Composable
fun Mono(t: String, size: androidx.compose.ui.unit.TextUnit, w: FontWeight, c: Color = Color.White) {
    Text(t, fontFamily = FontFamily.Monospace, fontSize = size, fontWeight = w, color = c)
}

@Composable fun VLine(w: androidx.compose.ui.unit.Dp, c: Color) {
    Box(Modifier.width(w).fillMaxHeight().background(c))
}
@Composable fun HLine(h: androidx.compose.ui.unit.Dp, c: Color) {
    Box(Modifier.height(h).fillMaxWidth().background(c))
}

@Composable
fun BigCell(label: String, value: String, m: Modifier) {
    Column(m.padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Mono(value, 20.sp, FontWeight.Black)
        Mono(label, 10.sp, FontWeight.Bold, Color.Gray)
    }
}

@Composable
fun SmallCell(label: String, value: String, m: Modifier) {
    Column(m.padding(vertical = 7.dp, horizontal = 2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Mono(value, 12.sp, FontWeight.Bold)
        Mono(label, 8.sp, FontWeight.Bold, Color.Gray)
    }
}

@Composable
fun NudgeButton(label: String, enabled: Boolean, m: Modifier, onClick: () -> Unit) {
    Box(m.border(3.dp, if (enabled) Color.White else Color.DarkGray)
        .clickable(enabled = enabled, onClick = onClick)
        .padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
        Mono(label, 20.sp, FontWeight.Black, if (enabled) Color.White else Color.DarkGray)
    }
}

@Composable
fun BigButton(label: String, fill: Color, enabled: Boolean, m: Modifier = Modifier.fillMaxWidth(),
              onClick: () -> Unit) {
    Box(m.background(if (enabled) fill else fill.copy(alpha = 0.3f))
        .clickable(enabled = enabled, onClick = onClick)
        .padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
        Mono(label, 20.sp, FontWeight.Black, Color.Black)
    }
}

@Composable
fun SettingsSheet(useMiles: Boolean, onUnits: (Boolean) -> Unit, onClose: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val p = prefs(ctx)
    var startEnd by remember { mutableStateOf(p.getFloat("startEndSpeed", 2.0f)) }
    var goal by remember { mutableStateOf(p.getFloat("goalSpeed", 4.0f)) }
    var rampMin by remember { mutableStateOf(p.getFloat("rampMinutes", 5.0f)) }
    var weight by remember { mutableStateOf(p.getFloat("weightKg", 70.0f)) }
    var goalType by remember { mutableStateOf(p.getString("goalType", "none") ?: "none") }
    var goalTimeMin by remember { mutableStateOf(p.getFloat("goalTimeMin", 30f)) }
    var goalKm by remember { mutableStateOf(p.getFloat("goalKm", 2f)) }
    var goalSteps by remember { mutableStateOf(p.getFloat("goalSteps", 3000f)) }

    fun save() {
        p.edit()
            .putFloat("startEndSpeed", startEnd).putFloat("goalSpeed", goal)
            .putFloat("rampMinutes", rampMin).putFloat("weightKg", weight)
            .putString("goalType", goalType).putFloat("goalTimeMin", goalTimeMin)
            .putFloat("goalKm", goalKm).putFloat("goalSteps", goalSteps)
            .apply()
    }
    val distUnit = if (useMiles) "MI" else "KM"

    Column(
        Modifier.fillMaxSize().background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(16.dp).padding(top = 24.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Mono("SETTINGS", 18.sp, FontWeight.Black)
            Spacer(Modifier.weight(1f))
            Box(Modifier.border(2.dp, Lime).clickable { save(); onClose() }
                .padding(horizontal = 10.dp, vertical = 5.dp)) {
                Mono("DONE", 12.sp, FontWeight.Black, Lime)
            }
        }
        Spacer(Modifier.height(20.dp))

        Mono("SPEEDS (KM/H)", 12.sp, FontWeight.Black, Color.Gray)
        StepperRow("START / END", "%.1f".format(startEnd), { startEnd = (startEnd - 0.1f).coerceAtLeast(0.8f) }, { startEnd = (startEnd + 0.1f).coerceAtMost(6.4f) })
        StepperRow("GOAL SPEED", "%.1f".format(goal), { goal = (goal - 0.1f).coerceAtLeast(0.8f) }, { goal = (goal + 0.1f).coerceAtMost(6.4f) })
        StepperRow("RAMP TIME", "${rampMin.toInt()} MIN", { rampMin = (rampMin - 1).coerceAtLeast(1f) }, { rampMin = (rampMin + 1).coerceAtMost(20f) })

        Spacer(Modifier.height(20.dp))
        Mono("SESSION GOAL", 12.sp, FontWeight.Black, Color.Gray)
        Row(Modifier.padding(vertical = 8.dp)) {
            listOf("none" to "NONE", "time" to "TIME", "km" to distUnit, "steps" to "STEPS").forEach { (tag, label) ->
                Box(Modifier.weight(1f)
                    .background(if (goalType == tag) Lime else Color.Black)
                    .border(1.dp, Color.White)
                    .clickable { goalType = tag }
                    .padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                    Mono(label, 11.sp, FontWeight.Black, if (goalType == tag) Color.Black else Color.White)
                }
            }
        }
        when (goalType) {
            "time" -> StepperRow("TARGET", "${goalTimeMin.toInt()} MIN", { goalTimeMin = (goalTimeMin - 5).coerceAtLeast(5f) }, { goalTimeMin = (goalTimeMin + 5).coerceAtMost(240f) })
            "km" -> StepperRow("TARGET", "%.1f %s".format(if (useMiles) goalKm / 1.609344f else goalKm, distUnit), { goalKm = (goalKm - 0.5f).coerceAtLeast(0.5f) }, { goalKm = (goalKm + 0.5f).coerceAtMost(30f) })
            "steps" -> StepperRow("TARGET", "${goalSteps.toInt()} STEPS", { goalSteps = (goalSteps - 500).coerceAtLeast(500f) }, { goalSteps = (goalSteps + 500).coerceAtMost(50000f) })
        }
        if (goalType != "none") {
            Mono("Ramps down to START/END as the goal approaches, then ends and syncs automatically.", 11.sp, FontWeight.Normal, Color.Gray)
        }

        Spacer(Modifier.height(20.dp))
        Mono("UNITS & BODY", 12.sp, FontWeight.Black, Color.Gray)
        Row(Modifier.padding(vertical = 8.dp)) {
            listOf(false to "KM", true to "MILES").forEach { (mi, label) ->
                Box(Modifier.weight(1f)
                    .background(if (useMiles == mi) Lime else Color.Black)
                    .border(1.dp, Color.White)
                    .clickable { onUnits(mi) }
                    .padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
                    Mono(label, 11.sp, FontWeight.Black, if (useMiles == mi) Color.Black else Color.White)
                }
            }
        }
        StepperRow("WEIGHT", "${weight.toInt()} KG", { weight = (weight - 1).coerceAtLeast(30f) }, { weight = (weight + 1).coerceAtMost(200f) })

        Spacer(Modifier.height(20.dp))
        Mono("Belt range 0.8–6.4 km/h. Calories are approximate. Sessions sync to Health Connect on END.", 11.sp, FontWeight.Normal, Color.Gray)
        Spacer(Modifier.height(24.dp))
        Text("made by lemonotype, hack all the things",
            fontFamily = FontFamily.Monospace, fontSize = 11.sp,
            fontWeight = FontWeight.Bold, color = Color.Gray,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
fun StepperRow(label: String, value: String, minus: () -> Unit, plus: () -> Unit) {
    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Mono(label, 13.sp, FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        Mono(value, 13.sp, FontWeight.Black, Lime)
        Spacer(Modifier.width(12.dp))
        Box(Modifier.border(2.dp, Color.White).clickable(onClick = minus).padding(horizontal = 12.dp, vertical = 4.dp)) {
            Mono("−", 16.sp, FontWeight.Black)
        }
        Spacer(Modifier.width(8.dp))
        Box(Modifier.border(2.dp, Color.White).clickable(onClick = plus).padding(horizontal = 12.dp, vertical = 4.dp)) {
            Mono("+", 16.sp, FontWeight.Black)
        }
    }
}
