/// Sağlık verisi (Health Connect) okuyucusu için Android yamaları.
///
/// KARAR: `health` paketi (MIT) yerine doğrudan Kotlin kanalı (`kocum/health`).
/// Gerekçe: `health` 14.x compileSdk 37 + AGP 9.1+ + FlutterFragmentActivity ister;
/// bu makinede yalnız android-36 kurulu ve MainActivity ink/genai yamalarıyla
/// FlutterActivity. Kanal yalnız `androidx.health.connect:connect-client`
/// (Apache-2.0) ekler, pubspec'e paket eklemez. Fonksiyonlar saf ve idempotenttir;
/// test/health_patch_test.dart ile denenir.
///
/// Salt OKUMA: yalnız uyku, nabız, dinlenme nabzı, HRV, SpO2, adım.
/// Stres için Health Connect'te veri türü YOKTUR.
library;

const healthMarker = 'kocum-health';
const healthDependency = 'androidx.health.connect:connect-client:1.1.0';

const healthPermissions = <String>[
  'android.permission.health.READ_SLEEP',
  'android.permission.health.READ_HEART_RATE',
  'android.permission.health.READ_RESTING_HEART_RATE',
  'android.permission.health.READ_STEPS',
  'android.permission.health.READ_HEART_RATE_VARIABILITY',
  'android.permission.health.READ_OXYGEN_SATURATION',
];

/// app/build.gradle.kts.
String patchHealthKts(String s) {
  if (s.contains(healthMarker)) return s;
  return '$s\n// $healthMarker: Health Connect okuyucu\ndependencies {\n    implementation("$healthDependency")\n}\n';
}

/// app/build.gradle (Groovy).
String patchHealthGroovy(String s) {
  if (s.contains(healthMarker)) return s;
  return "$s\n// $healthMarker: Health Connect okuyucu\ndependencies {\n    implementation '$healthDependency'\n}\n";
}

/// AndroidManifest.xml: izinler, `<queries>` paketi, gizlilik açıklaması etkinliği.
String patchHealthManifest(String m) {
  if (m.contains(healthMarker)) return m;
  var out = m;
  final perms = [for (final p in healthPermissions) '    <uses-permission android:name="$p"/>'].join('\n');
  out = out.replaceFirst('    <application', '    <!-- $healthMarker -->\n$perms\n    <application');

  // Android 13 ve altı: izin gerekçesi ekranı MainActivity'de.
  const rationale = '            <intent-filter>\n'
      '                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>\n'
      '            </intent-filter>\n';
  out = out.replaceFirst('        </activity>', '$rationale        </activity>');

  // Android 14+: izin kullanımı ekranı (activity-alias).
  const alias = '        <activity-alias\n'
      '            android:name="ViewPermissionUsageActivity"\n'
      '            android:exported="true"\n'
      '            android:targetActivity=".MainActivity"\n'
      '            android:permission="android.permission.START_VIEW_PERMISSION_USAGE">\n'
      '            <intent-filter>\n'
      '                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>\n'
      '                <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>\n'
      '            </intent-filter>\n'
      '        </activity-alias>\n';
  out = out.replaceFirst('    </application>', '$alias    </application>');

  const pkg = '        <package android:name="com.google.android.apps.healthdata"/>\n';
  if (out.contains('<queries>')) {
    out = out.replaceFirst('<queries>', '<queries>\n$pkg'.trimRight());
  } else {
    out = out.replaceFirst('</manifest>', '    <queries>\n$pkg    </queries>\n</manifest>');
  }
  return out;
}

const healthRegisterCall = 'flutterEngine.plugins.add(KocumHealthPlugin())';

/// MainActivity'ye kayıt satırı (`super.configureFlutterEngine` sonrasına).
String patchHealthMainActivity(String source) {
  if (source.contains(healthRegisterCall)) return source;
  return source.replaceFirstMapped(
    RegExp(r'^([ \t]*)super\.configureFlutterEngine\(flutterEngine\)[ \t]*$', multiLine: true),
    (m) => '${m[0]}\n${m[1]}$healthRegisterCall',
  );
}

/// Kanal ve izin akışı (tek Kotlin dosyası). Dart `'''` dizgesi: Kotlin dizge
/// şablonu ($) KULLANILMAZ.
String healthKotlin(String package) => '''
package $package

import android.app.Activity
import android.content.Intent
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.time.Instant
import java.time.LocalDateTime
import java.time.Period
import java.time.ZoneId
import kotlin.reflect.KClass
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/// Koçum: Health Connect SALT OKUMA köprüsü (kanal "kocum/health").
class KocumHealthPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var appContext: android.content.Context? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val requestCode = 7411

    private val types: Map<String, KClass<out Record>> = linkedMapOf(
        "sleep" to SleepSessionRecord::class,
        "heartRate" to HeartRateRecord::class,
        "restingHeartRate" to RestingHeartRateRecord::class,
        "hrv" to HeartRateVariabilityRmssdRecord::class,
        "oxygen" to OxygenSaturationRecord::class,
        "steps" to StepsRecord::class,
    )

    private fun allPermissions(): Set<String> = types.values.map { HealthPermission.getReadPermission(it) }.toSet()

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        appContext = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "kocum/health").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        binding = b
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { onDetachedFromActivity() }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) { onAttachedToActivity(b) }
    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
        activity = null
    }

    override fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val r = pending ?: return true
        pending = null
        scope.launch {
            try { r.success(statusMap()) } catch (t: Throwable) { r.error("health", t.message, null) }
        }
        return true
    }

    private suspend fun statusMap(): Map<String, Any?> {
        val ctx = appContext ?: return mapOf("availability" to "unsupported")
        val st = HealthConnectClient.getSdkStatus(ctx)
        val availability = when (st) {
            HealthConnectClient.SDK_AVAILABLE -> "available"
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "needsUpdate"
            else -> "needsInstall"
        }
        val granted = ArrayList<String>()
        if (st == HealthConnectClient.SDK_AVAILABLE) {
            val have = HealthConnectClient.getOrCreate(ctx).permissionController.getGrantedPermissions()
            for ((name, cls) in types) if (have.contains(HealthPermission.getReadPermission(cls))) granted.add(name)
        }
        return mapOf("availability" to availability, "granted" to granted)
    }

    private fun zone() = ZoneId.systemDefault()

    private suspend fun <T : Record> readAll(cls: KClass<T>, from: Long, to: Long, maxPages: Int = 20): List<T> {
        val client = HealthConnectClient.getOrCreate(appContext!!)
        val out = ArrayList<T>()
        var token: String? = null
        var pages = 0
        do {
            val resp = client.readRecords(
                ReadRecordsRequest(
                    recordType = cls,
                    timeRangeFilter = TimeRangeFilter.between(Instant.ofEpochMilli(from), Instant.ofEpochMilli(to)),
                    pageSize = 5000,
                    pageToken = token,
                )
            )
            out.addAll(resp.records)
            token = resp.pageToken
            pages++
        } while (token != null && pages < maxPages)
        return out
    }

    private fun stageName(t: Int): String = when (t) {
        SleepSessionRecord.STAGE_TYPE_DEEP -> "deep"
        SleepSessionRecord.STAGE_TYPE_LIGHT -> "light"
        SleepSessionRecord.STAGE_TYPE_REM -> "rem"
        SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED -> "awake"
        SleepSessionRecord.STAGE_TYPE_SLEEPING -> "sleeping"
        else -> "other"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                when (call.method) {
                    "status" -> result.success(statusMap())
                    "request" -> {
                        val a = activity
                        if (a == null || pending != null) {
                            result.error("health", "Etkinlik yok ya da istek sürüyor", null)
                        } else {
                            pending = result
                            val intent = PermissionController.createRequestPermissionResultContract()
                                .createIntent(a, allPermissions())
                            a.startActivityForResult(intent, requestCode)
                        }
                    }
                    "readSleep" -> {
                        val from = call.argument<Number>("from")!!.toLong()
                        val to = call.argument<Number>("to")!!.toLong()
                        result.success(readAll(SleepSessionRecord::class, from, to).map { r ->
                            mapOf(
                                "s" to r.startTime.toEpochMilli(),
                                "e" to r.endTime.toEpochMilli(),
                                "o" to r.metadata.dataOrigin.packageName,
                                "st" to r.stages.map { st ->
                                    mapOf("s" to st.startTime.toEpochMilli(), "e" to st.endTime.toEpochMilli(), "t" to stageName(st.stage))
                                },
                            )
                        })
                    }
                    "readDaily" -> {
                        val from = call.argument<Number>("from")!!.toLong()
                        val to = call.argument<Number>("to")!!.toLong()
                        val resting = try {
                            readAll(RestingHeartRateRecord::class, from, to).map {
                                mapOf("t" to it.time.toEpochMilli(), "v" to it.beatsPerMinute)
                            }
                        } catch (t: SecurityException) { emptyList() }
                        val hrv = try {
                            readAll(HeartRateVariabilityRmssdRecord::class, from, to).map {
                                mapOf("t" to it.time.toEpochMilli(), "v" to it.heartRateVariabilityMillis)
                            }
                        } catch (t: SecurityException) { emptyList() }
                        val steps = try {
                            val client = HealthConnectClient.getOrCreate(appContext!!)
                            val start = LocalDateTime.ofInstant(Instant.ofEpochMilli(from), zone())
                                .toLocalDate().atStartOfDay()
                            val end = LocalDateTime.ofInstant(Instant.ofEpochMilli(to), zone())
                            client.aggregateGroupByPeriod(
                                AggregateGroupByPeriodRequest(
                                    metrics = setOf(StepsRecord.COUNT_TOTAL),
                                    timeRangeFilter = TimeRangeFilter.between(start, end),
                                    timeRangeSlicer = Period.ofDays(1),
                                )
                            ).mapNotNull { g ->
                                val v = g.result[StepsRecord.COUNT_TOTAL]
                                if (v == null) null else mapOf(
                                    "t" to g.startTime.atZone(zone()).toInstant().toEpochMilli(), "v" to v
                                )
                            }
                        } catch (t: SecurityException) { emptyList() }
                        result.success(mapOf("resting" to resting, "hrv" to hrv, "steps" to steps))
                    }
                    "origins" -> {
                        val days = call.argument<Number>("days")!!.toLong()
                        val to = System.currentTimeMillis()
                        val from = to - days * 24L * 3600L * 1000L
                        val out = ArrayList<Map<String, Any?>>()
                        for ((name, cls) in types) {
                            try {
                                val counts = HashMap<String, Int>()
                                for (r in readAll(cls, from, to, 8)) {
                                    val p = r.metadata.dataOrigin.packageName
                                    counts[p] = (counts[p] ?: 0) + 1
                                }
                                for ((p, n) in counts) out.add(mapOf("type" to name, "pkg" to p, "n" to n))
                            } catch (t: SecurityException) {
                                // izin yok: bu tür atlanır
                            }
                        }
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("health", t.message, null)
            }
        }
    }
}
''';
