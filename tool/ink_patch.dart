/// Kalem yüzeyi A uygulaması (Android yerel): Jetpack Ink (`androidx.ink`) ile
/// düşük gecikmeli çizim, `androidx.input` ile hareket tahmini. Flutter'a
/// PlatformView olarak (`kocum/ink_surface`) gömülür. Fonksiyonlar saf metin
/// dönüşümleridir ve idempotenttir; test/ink_patch_test.dart ile denenir.
///
/// Lisanslar: androidx.ink ve androidx.input Apache-2.0.
library;

import 'package:kocum/features/ink/domain/predict_limit.dart';

const inkMarker = 'kocum-ink';

const inkDependencies = <String>[
  'androidx.ink:ink-authoring:1.0.0',
  'androidx.ink:ink-brush:1.0.0',
  'androidx.ink:ink-geometry:1.0.0',
  'androidx.ink:ink-rendering:1.0.0',
  'androidx.ink:ink-strokes:1.0.0',
  'androidx.input:input-motionprediction:1.0.1',
];

/// app/build.gradle.kts: bağımlılıklar. Zaten yamalıysa dokunmaz.
String patchInkKts(String s) {
  if (s.contains(inkMarker)) return s;
  final deps = inkDependencies
      .map((d) => '    implementation("$d")')
      .join('\n');
  return '$s\n// $inkMarker: Jetpack Ink + hareket tahmini\ndependencies {\n$deps\n}\n';
}

/// app/build.gradle (Groovy).
String patchInkGroovy(String s) {
  if (s.contains(inkMarker)) return s;
  final deps = inkDependencies.map((d) => "    implementation '$d'").join('\n');
  return "$s\n// $inkMarker: Jetpack Ink + hareket tahmini\ndependencies {\n$deps\n}\n";
}

const inkProguardMarker = '# kocum-ink-r8';

const inkProguardRules =
    '''
$inkProguardMarker
# Ink JNI kurallarını kendi paketiyle getirir; test kitaplığı sınıfları
# (CountingIdlingResource) uygulamada yoktur, uyarı kapatılır.
-dontwarn androidx.test.espresso.**
''';

/// proguard-rules.pro: kurallar eklenir (varsa korunur, iki kez eklenmez).
String patchInkProguard(String? existing) {
  final s = existing ?? '';
  if (s.contains(inkProguardMarker)) return s;
  return s.isEmpty ? inkProguardRules : '${s.trimRight()}\n\n$inkProguardRules';
}

const inkRegisterCall = 'KocumInk.register(flutterEngine)';

/// MainActivity'ye (genai şablonu bozulmadan) kayıt satırı ekler:
/// `super.configureFlutterEngine(flutterEngine)` satırının hemen sonrasına.
/// Satır bulunamazsa metin değişmez.
String patchInkMainActivity(String source) {
  if (source.contains(inkRegisterCall)) return source;
  return source.replaceFirstMapped(
    RegExp(
      r'^([ \t]*)super\.configureFlutterEngine\(flutterEngine\)[ \t]*$',
      multiLine: true,
    ),
    (m) => '${m[0]}\n${m[1]}$inkRegisterCall',
  );
}

/// Fabrika, kayıt nesnesi ve çizim görünümü (tek Kotlin dosyası).
/// Not: Dart `'''` dizgesi; Kotlin dizge şablonu ($) KULLANILMAZ. Tek istisna: tahmin
/// sınırı sabitleri Dart tarafından (`PredictLimits`) basılır (tek kaynak).
String inkKotlin(String package) =>
    '''
package $package

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.util.Log
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.ink.brush.Brush
import androidx.ink.brush.InputToolType
import androidx.ink.brush.StockBrushes
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.strokes.InProgressStroke
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import androidx.ink.strokes.StrokeInput
import androidx.input.motionprediction.MotionEventPredictor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/// Koçum: kalem yüzeyi (A uygulaması). Sözleşme: kocum/ink_surface, kocum/ink/<viewId>.
object KocumInk {
    fun register(engine: FlutterEngine) {
        engine.platformViewsController.registry.registerViewFactory(
            "kocum/ink_surface",
            KocumInkFactory(engine.dartExecutor.binaryMessenger)
        )
    }
}

class KocumInkFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? Map<*, *>
        val tool = params?.get("tool") as? String ?: "pen"
        val color = (params?.get("color") as? Number)?.toInt() ?: 0xFF000000.toInt()
        val width = (params?.get("width") as? Number)?.toFloat() ?: 2f
        val channel = MethodChannel(messenger, "kocum/ink/" + viewId)
        val view = KocumInkView(context, channel, tool, color, width)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setBrush" -> {
                    view.setBrush(
                        call.argument<String>("tool") ?: "pen",
                        (call.argument<Number>("color") ?: 0xFF000000.toInt()).toInt(),
                        (call.argument<Number>("width") ?: 2.0).toFloat()
                    )
                    result.success(null)
                }
                "clear" -> {
                    view.clearAll()
                    result.success(null)
                }
                "setInputMode" -> {
                    view.stylusOnly = call.argument<Boolean>("stylusOnly") ?: true
                    result.success(null)
                }
                "setTransform" -> {
                    // Parmakla kaydırma/yakınlaştırmayı Dart yönetir; görünüm = dünya * scale + (dx, dy)
                    // (dx, dy mantıksal piksel). Çizgiler dünya koordinatında kalır.
                    view.setTransform(
                        (call.argument<Number>("scale") ?: 1.0).toFloat(),
                        (call.argument<Number>("dx") ?: 0.0).toFloat(),
                        (call.argument<Number>("dy") ?: 0.0).toFloat()
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        return object : PlatformView {
            override fun getView(): View = view
            override fun dispose() {
                channel.setMethodCallHandler(null)
                view.release()
            }
        }
    }
}

/// Kalem hareket tahmininin hıza göre sınırlanması. SAF mantık (Android'e bağlı değil);
/// lib/features/ink/domain/predict_limit.dart ile birebir aynıdır, sabitleri oradan gelir.
/// Birimler: mantıksal piksel (dp), milisaniye. Sorun: tahminci her harekette ilerisini verir;
/// kalem durunca bile titreşim tahmin ucunu sağa sola oynatır. Bu yüzden: durma hızının
/// altında tahmin YOK; üstünde tahmin yolu hız x süre ile ve mutlak sınırla kırpılır.
class PredictLimiter {
    companion object {
        // Hız penceresi: son bu kadar gerçek nokta.
        const val WINDOW = ${PredictLimits.window}
        // Bu hızın (dp/ms) altı "durdu" sayılır; tahmin verilmez.
        const val STILL_SPEED = ${PredictLimits.stillSpeed}f
        // Art arda STILL_COUNT harekette her biri STILL_MOVE dp'den az oynadıysa kalem durmuştur.
        const val STILL_COUNT = ${PredictLimits.stillCount}
        const val STILL_MOVE = ${PredictLimits.stillMove}f
        // İzin verilen en uzun tahmin yolu = hız x HORIZON_MS x LEAD_SCALE (en çok MAX_LEAD_DP).
        const val HORIZON_MS = ${PredictLimits.horizonMs}f
        const val LEAD_SCALE = ${PredictLimits.leadScale}f
        const val MAX_LEAD_DP = ${PredictLimits.maxLeadDp}f
    }

    private val xs = FloatArray(WINDOW)
    private val ys = FloatArray(WINDOW)
    private val ts = LongArray(WINDOW)
    private var n = 0
    private var stillRun = 0

    fun reset() {
        n = 0
        stillRun = 0
    }

    fun record(x: Float, y: Float, t: Long) {
        if (n > 0) {
            val dx = x - xs[n - 1]
            val dy = y - ys[n - 1]
            stillRun = if (sqrt(dx * dx + dy * dy) < STILL_MOVE) stillRun + 1 else 0
        }
        if (n == WINDOW) {
            for (i in 1 until WINDOW) {
                xs[i - 1] = xs[i]
                ys[i - 1] = ys[i]
                ts[i - 1] = ts[i]
            }
            n--
        }
        xs[n] = x
        ys[n] = y
        ts[n] = t
        n++
    }

    fun speed(): Float {
        if (n < 2) return 0f
        val dt = ts[n - 1] - ts[0]
        if (dt <= 0L) return 0f
        val dx = xs[n - 1] - xs[0]
        val dy = ys[n - 1] - ys[0]
        return sqrt(dx * dx + dy * dy) / dt
    }

    fun isStill(): Boolean = n < 2 || stillRun >= STILL_COUNT || speed() < STILL_SPEED

    fun maxLead(): Float =
        if (isStill()) 0f else min(speed() * HORIZON_MS * LEAD_SCALE, MAX_LEAD_DP)

    /// Tahmin noktalarını (gerçek son noktadan başlayarak, dp) YERİNDE kırpar; kalan sayıyı
    /// döndürür. 0 dönerse tahmin verilmez (boş tahmin = ekranda asılı tahmin kalmaz).
    fun clip(px: FloatArray, py: FloatArray, pt: LongArray, count: Int): Int {
        val limit = maxLead()
        if (limit <= 0f || count <= 0 || n == 0) return 0
        var cx = xs[n - 1]
        var cy = ys[n - 1]
        var ct = ts[n - 1]
        var used = 0f
        var kept = 0
        for (i in 0 until count) {
            val dx = px[i] - cx
            val dy = py[i] - cy
            val seg = sqrt(dx * dx + dy * dy)
            if (used + seg <= limit) {
                cx = px[i]; cy = py[i]; ct = pt[i]
                used += seg
                kept++
                continue
            }
            if (seg > 0f) {
                val f = (limit - used) / seg
                if (f > 0f) {
                    val nx = cx + dx * f
                    val ny = cy + dy * f
                    val nt = ct + ((pt[i] - ct) * f).toLong()
                    px[kept] = nx; py[kept] = ny; pt[kept] = nt
                    kept++
                }
            }
            break
        }
        return kept
    }
}

/// Dokunuşu onTouchEvent'inde alır: yalnızca kalem çizer; parmak ve avuç yok sayılır
/// (çizilmez, Dart'a gönderilmez). DİKKAT: AndroidView dokunuşu Dart üzerinden yerele
/// SENTETİK olay olarak iletir; burada false dönmek olayı Flutter'a iade ETMEZ, bu yüzden
/// hep true döneriz. Dart tarafı "yalnız kalem" kipinde parmağı yerele HİÇ iletmez ve
/// parmakla kaydırma/yakınlaştırmayı kendisi yapar, sonucu `setTransform` ile bize söyler.
///
/// ÇİZİM: devam eden çizgi de, biten çizgiler de AYNI görünümün onDraw'unda çizilir
/// (CanvasStrokeRenderer). Ink'in ön tampon görünümü (ayrı yüzey) KULLANILMAZ: o yüzey,
/// PlatformView dokusunun içinde değil pencerede kendi konumuyla durur ve çizgiyi kalem ucunun YUKARISINDA gösteriyordu (tabletle doğrulanacak).
/// Ön tampon yoksa konum kayması olamaz; bedeli biraz fazla gecikme olabilir.
///
/// KOORDİNATLAR: MotionEvent x/y görünüm yerel FİZİKSEL pikseldir. Çizgiler DÜNYA
/// koordinatında (zum 1, fiziksel piksel) saklanır; dünya -> görünüm: v = d * scale + t
/// (worldToView). Giriş noktaları (x - tx) / scale ile dünyaya çevrilir. Dart'a mantıksal
/// DÜNYA koordinatı (d / density) gider.
class KocumInkView(
    context: Context,
    private val channel: MethodChannel,
    private var tool: String,
    private var color: Int,
    private var widthLogical: Float
) : FrameLayout(context) {
    var stylusOnly = true

    private val density = resources.displayMetrics.density
    private val worldToView = Matrix()
    private var scale = 1f
    private var tx = 0f // fiziksel piksel
    private var ty = 0f
    private val renderer = CanvasStrokeRenderer.create()
    private val finished = ArrayList<Stroke>()
    private val predictor = MotionEventPredictor.newInstance(this)
    private val limiter = PredictLimiter()

    private var live: InProgressStroke? = null
    private var strokeT0 = 0L
    private var lastElapsed = 0L
    private val realBatch = MutableStrokeInputBatch()
    private val predictedBatch = MutableStrokeInputBatch()
    // Tahmin yok (kalem durdu / yavaş): ekranda asılı tahmin kalmasın diye bu boş toplu verilir.
    private val noPrediction = MutableStrokeInputBatch()
    private var predX = FloatArray(16)
    private var predY = FloatArray(16)
    private var predT = LongArray(16)

    private val layer = object : View(context) {
        override fun onDraw(canvas: Canvas) {
            for (s in finished) renderer.draw(canvas, s, worldToView)
            val l = live
            if (l != null) renderer.draw(canvas, l, worldToView)
        }
    }

    private var brush = makeBrush()
    private var activePointer = -1
    private var nextId = 0
    private var activeId = 0
    private var activeTool = InputToolType.STYLUS

    // Gecikme ölçümü "A giris->vsync": olayın eventTime'ı (uptimeMillis) ile onu işleyen
    // ilk Choreographer karesinin başlangıcı (frameTimeNanos, aynı saat) farkı. Dart tarafı
    // B için hem "giris->vsync" hem "giris->raster" yazar; A yalnız vsync'e kadar ölçer.
    private var pendingEventTime = -1L
    private var logCount = 0
    private val frameCallback = Choreographer.FrameCallback { frameTimeNanos ->
        val t = pendingEventTime
        pendingEventTime = -1L
        if (t >= 0) {
            logCount++
            if (logCount % 10 == 1) {
                Log.i("KocumInk", "A giris->vsync ms=" + (frameTimeNanos / 1000000L - t))
            }
        }
    }

    init {
        addView(layer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    private fun makeBrush(): Brush {
        val family = if (tool == "highlighter") StockBrushes.highlighter() else StockBrushes.pressurePen()
        return Brush.createWithColorIntArgb(family, color, widthLogical * density, 0.1f)
    }

    fun setBrush(newTool: String, newColor: Int, newWidth: Float) {
        tool = newTool
        color = newColor
        widthLogical = newWidth
        brush = makeBrush()
    }

    /// dx, dy mantıksal piksel; scale sınırlandırılır (0 ya da NaN bölme hatası vermesin).
    fun setTransform(newScale: Float, dx: Float, dy: Float) {
        scale = if (newScale.isNaN() || newScale < 0.05f) 1f else newScale
        tx = if (dx.isNaN()) 0f else dx * density
        ty = if (dy.isNaN()) 0f else dy * density
        worldToView.setScale(scale, scale)
        worldToView.postTranslate(tx, ty)
        layer.invalidate()
    }

    fun clearAll() {
        live = null
        activePointer = -1
        finished.clear()
        layer.invalidate()
    }

    fun release() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        live = null
    }

    private fun accepts(e: MotionEvent, index: Int): Boolean =
        e.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS || !stylusOnly

    private fun worldX(viewPx: Float): Float = (viewPx - tx) / scale
    private fun worldY(viewPx: Float): Float = (viewPx - ty) / scale

    private fun emit(name: String, e: MotionEvent, index: Int, historyPos: Int) {
        val x: Float
        val y: Float
        val p: Float
        val t: Long
        val tilt: Float
        if (historyPos < 0) {
            x = e.getX(index); y = e.getY(index); p = e.getPressure(index)
            t = e.eventTime; tilt = e.getAxisValue(MotionEvent.AXIS_TILT, index)
        } else {
            x = e.getHistoricalX(index, historyPos); y = e.getHistoricalY(index, historyPos)
            p = e.getHistoricalPressure(index, historyPos)
            t = e.getHistoricalEventTime(historyPos)
            tilt = e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, index, historyPos)
        }
        channel.invokeMethod(name, mapOf(
            "id" to activeId,
            "x" to (worldX(x) / density).toDouble(),
            "y" to (worldY(y) / density).toDouble(),
            "pressure" to p.coerceIn(0f, 1f).toDouble(),
            "tilt" to tilt.toDouble(),
            "t" to t
        ))
    }

    private fun stampLatency(e: MotionEvent) {
        if (pendingEventTime < 0) {
            pendingEventTime = e.eventTime
            Choreographer.getInstance().postFrameCallback(frameCallback)
        }
    }

    /// Bir girişi (görünüm pikseli) dünya koordinatında toplu ekler. Süre, çizgi başından
    /// beri geçen ms; geriye gitmez (Ink geriye giden süreyi reddeder).
    private fun addInput(batch: MutableStrokeInputBatch, x: Float, y: Float, t: Long, p: Float, tilt: Float, floor: Long): Long {
        val el = max(t - strokeT0, floor)
        val tl = if (tilt >= 0f && tilt <= 1.5708f) tilt else StrokeInput.NO_TILT
        batch.add(
            activeTool, worldX(x), worldY(y), el,
            StrokeInput.NO_STROKE_UNIT_LENGTH, p.coerceIn(0f, 1f), tl, StrokeInput.NO_ORIENTATION
        )
        return el
    }

    /// Olayın (tarihçe + şimdiki) gerçek noktalarını realBatch'e ve hız penceresine ekler.
    private fun collectReal(e: MotionEvent, index: Int) {
        for (h in 0 until e.historySize) {
            val x = e.getHistoricalX(index, h)
            val y = e.getHistoricalY(index, h)
            val t = e.getHistoricalEventTime(h)
            lastElapsed = addInput(
                realBatch, x, y, t, e.getHistoricalPressure(index, h),
                e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, index, h), lastElapsed
            )
            limiter.record(x / density, y / density, t)
        }
        val x = e.getX(index)
        val y = e.getY(index)
        lastElapsed = addInput(
            realBatch, x, y, e.eventTime, e.getPressure(index),
            e.getAxisValue(MotionEvent.AXIS_TILT, index), lastElapsed
        )
        limiter.record(x / density, y / density, e.eventTime)
    }

    /// Tahmin noktalarını hıza göre kırpıp predictedBatch'e koyar. Kalem durmuş ya da yavaşsa
    /// (isStill) tahminciye hiç sorulmaz: predictedBatch boş kalır (prediction = null yolu).
    private fun collectPredicted(e: MotionEvent, index: Int) {
        predictedBatch.clear()
        if (limiter.isStill()) return
        val pe = predictor.predict() ?: return
        try {
            val pi = max(0, pe.findPointerIndex(activePointer))
            val n = pe.historySize + 1
            if (predX.size < n) {
                predX = FloatArray(n); predY = FloatArray(n); predT = LongArray(n)
            }
            for (k in 0 until n) {
                if (k < pe.historySize) {
                    predX[k] = pe.getHistoricalX(pi, k) / density
                    predY[k] = pe.getHistoricalY(pi, k) / density
                    predT[k] = pe.getHistoricalEventTime(k)
                } else {
                    predX[k] = pe.getX(pi) / density
                    predY[k] = pe.getY(pi) / density
                    predT[k] = pe.eventTime
                }
            }
            val kept = limiter.clip(predX, predY, predT, n)
            var floor = lastElapsed
            val p = e.getPressure(index)
            for (k in 0 until kept) {
                floor = addInput(predictedBatch, predX[k] * density, predY[k] * density, predT[k], p, StrokeInput.NO_TILT, floor)
            }
        } finally {
            pe.recycle()
        }
    }

    private fun push(s: InProgressStroke, withPrediction: Boolean) {
        try {
            s.enqueueInputs(realBatch, if (withPrediction) predictedBatch else noPrediction)
            s.updateShape(lastElapsed)
        } catch (ex: IllegalArgumentException) {
            // Ink geçersiz girişi (ör. süre geri gitti) reddetti: çizim düşmesin, yok say.
            Log.w("KocumInk", "giris reddedildi: " + ex.message)
        }
        realBatch.clear()
        layer.invalidate()
    }

    private fun startStroke(e: MotionEvent, index: Int) {
        requestUnbufferedDispatch(e)
        activePointer = e.getPointerId(index)
        activeId = nextId++
        activeTool = if (e.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS) InputToolType.STYLUS else InputToolType.TOUCH
        strokeT0 = e.eventTime
        lastElapsed = 0L
        limiter.reset()
        predictor.record(e)
        if (tool != "eraser") {
            val s = InProgressStroke()
            s.start(brush)
            realBatch.clear()
            collectReal(e, index)
            live = s
            push(s, false)
        }
        stampLatency(e)
        emit("strokeStart", e, index, -1)
    }

    private fun endStroke(e: MotionEvent, index: Int) {
        predictor.record(e)
        val s = live
        if (s != null) {
            realBatch.clear()
            collectReal(e, index)
            push(s, false) // bitişte tahmin yok
            try {
                s.finishInput()
                var guard = 0
                var el = lastElapsed
                while (s.isUpdateNeeded() && guard++ < 200) {
                    el += 16
                    s.updateShape(el)
                }
                finished.add(s.toImmutable())
            } catch (ex: IllegalStateException) {
                Log.w("KocumInk", "cizgi bitirilemedi: " + ex.message)
            }
            live = null
            layer.invalidate()
        }
        emit("strokeEnd", e, index, -1)
        activePointer = -1
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Avuç/parmak ilk gelirse çizmeyiz ama true döneriz: jestin sonraki
                // işaretçileri (kalemin ACTION_POINTER_DOWN'u) bize ulaşsın.
                if (accepts(e, 0)) startStroke(e, 0)
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = e.actionIndex
                if (activePointer < 0 && accepts(e, idx)) startStroke(e, idx)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val i = e.findPointerIndex(activePointer)
                if (i < 0) return true
                predictor.record(e)
                val s = live
                if (s != null) {
                    realBatch.clear()
                    collectReal(e, i)
                    collectPredicted(e, i)
                    push(s, true)
                }
                stampLatency(e)
                for (h in 0 until e.historySize) emit("strokePoint", e, i, h)
                emit("strokePoint", e, i, -1)
                return true
            }
            MotionEvent.ACTION_POINTER_UP -> {
                val idx = e.actionIndex
                if (activePointer >= 0 && e.getPointerId(idx) == activePointer) endStroke(e, idx)
                return true
            }
            MotionEvent.ACTION_UP -> {
                val i = e.findPointerIndex(activePointer)
                if (i >= 0) endStroke(e, i)
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (activePointer >= 0) {
                    live = null
                    layer.invalidate()
                    channel.invokeMethod("strokeCancel", mapOf("id" to activeId))
                    activePointer = -1
                }
                return true
            }
        }
        return true
    }
}
''';
