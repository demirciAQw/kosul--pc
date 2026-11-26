/// Ink katmanı (Android yerel): FlutterView'in ÜSTÜNE tam pencere saydam yerel katman.
/// Kalem çizgisini Google Ink (`androidx.ink.authoring.InProgressStrokesView`) ıslak çizer
/// (ön tampon, düşük gecikme); biten çizgi Dart'a gider, kalıcı kayıt ve kuru çizim Flutter'da.
/// Sözleşme: `lib/features/ink/data/ink_overlay_codec.dart`. Bağımlılıklar `tool/ink_patch.dart`
/// içindeki `inkDependencies` ile gelir (yeni paket yok). Fonksiyonlar saf metin dönüşümüdür,
/// idempotenttir; test/ink_overlay_patch_test.dart ile denenir.
///
/// MainActivity yama zinciri: genai şablonu -> health -> ink -> ink katmanı. Her yama
/// `super.configureFlutterEngine(flutterEngine)` satırının hemen sonrasına tek satır ekler
/// ve kendi çağrısı varsa dokunmaz; sıra önemsizdir.
///
/// KOTLIN BAĞIMLILIĞI: `PredictLimiter` sınıfı `KocumInk.kt` içindedir (tool/ink_patch.dart);
/// iki dosya aynı pakette birlikte üretilir.
library;

const inkOverlayCall = 'KocumInkOverlay.attach(this, flutterEngine)';

/// MainActivity'ye (diğer yamalar bozulmadan) bağlama satırı ekler. Satır yoksa metin değişmez.
String patchInkOverlayMainActivity(String source) {
  if (source.contains(inkOverlayCall)) return source;
  return source.replaceFirstMapped(
    RegExp(r'^([ \t]*)super\.configureFlutterEngine\(flutterEngine\)[ \t]*$', multiLine: true),
    (m) => '${m[0]}\n${m[1]}$inkOverlayCall',
  );
}

/// Tek Kotlin dosyası. Not: Dart `'''` dizgesi; Kotlin dizge şablonu ($) KULLANILMAZ
/// (yalnız paket adı). Sürekli `"""` yok.
String inkOverlayKotlin(String package) =>
    '''
package $package

import android.app.Activity
import android.graphics.Path
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.brush.StockBrushes
import androidx.ink.strokes.Stroke
import androidx.input.motionprediction.MotionEventPredictor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Koçum: Ink katmanı. Kanal: kocum/ink_overlay (sözleşme Dart tarafında).
/// Kalem DOWN olayı Dart'ın bildirdiği bir sayfa dikdörtgeninde ise ve mod pen/highlighter ise
/// dizinin TAMAMI burada tüketilir (Ink ıslak çizer); aksi hâlde olay alttaki FlutterView'e gider.
object KocumInkOverlay {
    private const val TAG = "KocumInkOverlay"

    fun attach(activity: Activity, engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "kocum/ink_overlay")
        val overlay: InkOverlay? = try {
            InkOverlay(activity, channel)
        } catch (t: Throwable) {
            Log.e(TAG, "Ink katmanı oluşturulamadı", t)
            null
        }
        channel.setMethodCallHandler { call, result ->
            if (overlay == null) {
                if (call.method == "ping") result.success(false) else result.success(null)
            } else {
                overlay.handle(call, result)
            }
        }
        if (overlay == null) return
        // FlutterActivity içeriği (FlutterView) configureFlutterEngine'den SONRA setContentView ile
        // kurar ve içerik kökünü temizler; katmanı bu yüzden onCreate bittikten sonra ekleriz.
        activity.window.decorView.post {
            try {
                val content = activity.findViewById<ViewGroup>(android.R.id.content)
                if (overlay.parent == null) {
                    // Kalem aşağıdayken gelen parmak/avuç ikinci işaretçisi alttaki FlutterView'e
                    // AYRI dizi olarak gitmesin: bölme kapalı.
                    content.setMotionEventSplittingEnabled(false)
                    content.addView(
                        overlay,
                        FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    )
                }
                overlay.start()
            } catch (t: Throwable) {
                Log.e(TAG, "Ink katmanı eklenemedi", t)
                overlay.failed = true
            }
        }
    }
}

class InkOverlay(activity: Activity, private val channel: MethodChannel) : FrameLayout(activity) {
    companion object {
        private const val TAG = "KocumInkOverlay"
        /// Kalem ACTION_CANCEL (avuç değince Goodix gönderir): çizgi KAYDEDİLİR (Flutter B yolundaki
        /// davranışın aynısı). FLAG_CANCELED (sistem "bu olay kasıtlı değil" dedi) ise atılır.
        const val CANCEL_KEEPS_STROKE = true
        const val FLAG_CANCELED_BIT = 0x20
    }

    /// Başlatılamadıysa Dart'a "yok" denir ve olaylar hep alttaki görünüme gider.
    var failed = false

    private class Rec(val id: Int, val family: String, val argb: Int, val sizePx: Float, val t0: Long) {
        var pts = FloatArray(6 * 64)
        var n = 0
        fun add(x: Float, y: Float, t: Long, p: Float, tilt: Float, ori: Float) {
            if ((n + 1) * 6 > pts.size) pts = pts.copyOf(pts.size * 2)
            val o = n * 6
            pts[o] = x; pts[o + 1] = y; pts[o + 2] = (t - t0).toFloat()
            pts[o + 3] = p; pts[o + 4] = tilt; pts[o + 5] = ori
            n++
        }
        fun array(): FloatArray = pts.copyOf(n * 6)
    }

    private val density = resources.displayMetrics.density
    private val main = Handler(Looper.getMainLooper())
    private val strokes = InProgressStrokesView(activity)
    private val predictor = MotionEventPredictor.newInstance(this)
    private val limiter = PredictLimiter()

    private var mode = "off"
    private var family = "pressurePen"
    private var argb = 0xFF000000.toInt()
    private var sizePx = 4f
    private var epsilon = 0.1f
    private var brush: Brush = makeBrush()
    private val regions = ArrayList<RectF>()
    private val masks = ArrayList<RectF>()

    private var penPointerId = -1
    private var current: InProgressStrokeId? = null
    private var rec: Rec? = null
    private var nextId = 1
    private val inkIds = HashMap<Int, InProgressStrokeId>()
    private val arrived = HashSet<InProgressStrokeId>()
    private val pendingRelease = HashSet<InProgressStrokeId>()

    init {
        setMotionEventSplittingEnabled(false)
        addView(strokes, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        strokes.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
            override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                for (key in strokes.keys) {
                    if (pendingRelease.remove(key)) removeInk(key) else arrived.add(key)
                }
            }
        })
        applyMask()
    }

    fun start() {
        try {
            strokes.eagerInit()
        } catch (t: Throwable) {
            Log.w(TAG, "eagerInit", t)
        }
    }

    private fun makeBrush(): Brush {
        val fam = when (family) {
            "marker" -> StockBrushes.marker()
            "highlighter" -> StockBrushes.highlighter()
            else -> StockBrushes.pressurePen()
        }
        return Brush.createWithColorIntArgb(fam, argb, sizePx, epsilon)
    }

    private fun rectOf(o: Any?): RectF? {
        val l = o as? List<*> ?: return null
        if (l.size < 4) return null
        val v = l.map { (it as? Number)?.toFloat() ?: return null }
        return RectF(v[0], v[1], v[2], v[3])
    }

    private fun readRects(arg: Any?, into: ArrayList<RectF>) {
        into.clear()
        val list = arg as? List<*> ?: return
        for (o in list) rectOf(o)?.let { into.add(it) }
    }

    /// Islak çizgi yalnız izinli bölgelerde ve maske dışında görünsün (araç çubuğunun üstüne çizilmesin).
    private fun applyMask() {
        val path = Path()
        for (r in regions) path.addRect(r, Path.Direction.CW)
        if (masks.isNotEmpty()) {
            val hole = Path()
            for (r in masks) hole.addRect(r, Path.Direction.CW)
            path.op(hole, Path.Op.DIFFERENCE)
        }
        try {
            strokes.maskPath = path
        } catch (t: Throwable) {
            Log.w(TAG, "maskPath", t)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "ping" -> result.success(!failed)
                "setMode" -> {
                    val m = call.argument<String>("mode") ?: "off"
                    mode = if (m == "pen" || m == "highlighter") m else "off"
                    result.success(null)
                }
                "setBrush" -> {
                    family = call.argument<String>("family") ?: "pressurePen"
                    argb = (call.argument<Number>("argb") ?: 0xFF000000.toInt()).toInt()
                    sizePx = (call.argument<Number>("sizePx") ?: 4.0).toFloat().coerceAtLeast(0.5f)
                    epsilon = (call.argument<Number>("epsilon") ?: 0.1).toFloat().coerceAtLeast(0.01f)
                    brush = makeBrush()
                    result.success(null)
                }
                "setRegions" -> {
                    readRects(call.argument<Any>("rects"), regions)
                    applyMask()
                    result.success(null)
                }
                "setMask" -> {
                    readRects(call.argument<Any>("rects"), masks)
                    applyMask()
                    result.success(null)
                }
                "releaseStrokes" -> {
                    val ids = call.argument<List<*>>("ids") ?: emptyList<Any>()
                    for (o in ids) {
                        val inkId = inkIds.remove((o as? Number)?.toInt() ?: continue) ?: continue
                        if (arrived.remove(inkId)) removeInk(inkId) else pendingRelease.add(inkId)
                    }
                    result.success(null)
                }
                "cancelCurrent" -> {
                    cancelCurrentStroke()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "kanal çağrısı: " + call.method, t)
            result.error("ink_overlay", t.message, null)
        }
    }

    private fun removeInk(id: InProgressStrokeId) {
        main.post {
            try {
                strokes.removeFinishedStrokes(setOf(id))
            } catch (t: Throwable) {
                Log.w(TAG, "removeFinishedStrokes", t)
            }
        }
    }

    private fun inRegion(x: Float, y: Float): Boolean {
        var inside = false
        for (r in regions) if (r.contains(x, y)) { inside = true; break }
        if (!inside) return false
        for (r in masks) if (r.contains(x, y)) return false
        return true
    }

    private fun accepts(e: MotionEvent): Boolean {
        if (failed || mode == "off") return false
        if (e.getToolType(0) != MotionEvent.TOOL_TYPE_STYLUS) return false // silgi ucu ve parmak Flutter'da
        val side = MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_STYLUS_SECONDARY
        if ((e.buttonState and side) != 0) return false // yan düğme: Flutter (kement vb.)
        return inRegion(e.x, e.y)
    }

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        if (penPointerId < 0) {
            if (e.actionMasked != MotionEvent.ACTION_DOWN || !accepts(e)) return false
            return begin(e)
        }
        val index = e.findPointerIndex(penPointerId)
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE -> if (index >= 0) move(e, index)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP ->
                if (e.getPointerId(e.actionIndex) == penPointerId) end(e, index)
            MotionEvent.ACTION_CANCEL -> cancelled(e, index)
            else -> {} // POINTER_DOWN: ikinci temas (avuç/parmak) yutulur, çizgi sürer
        }
        return true
    }

    private fun begin(e: MotionEvent): Boolean {
        try {
            requestUnbufferedDispatch(e)
            val pid = e.getPointerId(0)
            limiter.reset()
            predictor.record(e)
            val inkId = strokes.startStroke(e, pid, brush)
            val id = nextId++
            val r = Rec(id, family, argb, sizePx, e.eventTime)
            penPointerId = pid
            current = inkId
            rec = r
            inkIds[id] = inkId
            recordPoints(e, 0, r)
            channel.invokeMethod("strokeStart", mapOf("id" to id))
            return true
        } catch (t: Throwable) {
            Log.e(TAG, "startStroke", t)
            resetStroke()
            return false
        }
    }

    private fun recordPoints(e: MotionEvent, index: Int, r: Rec) {
        for (h in 0 until e.historySize) {
            r.add(
                e.getHistoricalX(index, h), e.getHistoricalY(index, h), e.getHistoricalEventTime(h),
                e.getHistoricalPressure(index, h).coerceIn(0f, 1f),
                e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, index, h),
                e.getHistoricalOrientation(index, h)
            )
        }
        r.add(
            e.getX(index), e.getY(index), e.eventTime, e.getPressure(index).coerceIn(0f, 1f),
            e.getAxisValue(MotionEvent.AXIS_TILT, index), e.getOrientation(index)
        )
    }

    private fun move(e: MotionEvent, index: Int) {
        val id = current ?: return
        val r = rec ?: return
        try {
            predictor.record(e)
            for (h in 0 until e.historySize) {
                limiter.record(e.getHistoricalX(index, h) / density, e.getHistoricalY(index, h) / density, e.getHistoricalEventTime(h))
            }
            limiter.record(e.getX(index) / density, e.getY(index) / density, e.eventTime)
            // Tahmin: kalem durduysa ya da yavaşsa verilmez (asılı tahmin kalmasın); hızlıysa
            // Ink'in tahmini olduğu gibi kullanılır (yol uzunluğunu kırpmak bu API'de yok).
            val predicted = if (limiter.isStill()) null else predictor.predict()
            try {
                strokes.addToStroke(e, penPointerId, id, predicted)
            } finally {
                predicted?.recycle()
            }
            recordPoints(e, index, r)
        } catch (t: Throwable) {
            Log.e(TAG, "addToStroke", t)
        }
    }

    private fun end(e: MotionEvent, index: Int) {
        val id = current
        val r = rec
        if (id == null || r == null) {
            resetStroke()
            return
        }
        try {
            if (index >= 0) recordPoints(e, index, r)
            strokes.finishStroke(e, penPointerId, id)
        } catch (t: Throwable) {
            Log.e(TAG, "finishStroke", t)
        }
        emitFinished(r)
        resetStroke()
    }

    private fun cancelled(e: MotionEvent, index: Int) {
        val id = current
        val r = rec
        if (id == null || r == null) {
            resetStroke()
            return
        }
        val flagged = (e.flags and FLAG_CANCELED_BIT) != 0
        if (CANCEL_KEEPS_STROKE && !flagged) {
            // Çizgi biter (UP gibi): ıslak çizgi el değişene dek ekranda kalır.
            val up = MotionEvent.obtain(e)
            try {
                up.action = MotionEvent.ACTION_UP
                if (index >= 0) recordPoints(e, index, r)
                strokes.finishStroke(up, penPointerId, id)
            } catch (t: Throwable) {
                Log.e(TAG, "finishStroke(cancel)", t)
            } finally {
                up.recycle()
            }
            emitFinished(r)
        } else {
            try {
                strokes.cancelStroke(id, e)
            } catch (t: Throwable) {
                Log.e(TAG, "cancelStroke", t)
            }
            inkIds.remove(r.id)
            channel.invokeMethod("strokeCanceled", mapOf("id" to r.id))
        }
        resetStroke()
    }

    private fun cancelCurrentStroke() {
        val id = current
        val r = rec
        if (id == null || r == null) return
        try {
            strokes.cancelStroke(id)
        } catch (t: Throwable) {
            Log.e(TAG, "cancelStroke", t)
        }
        inkIds.remove(r.id)
        channel.invokeMethod("strokeCanceled", mapOf("id" to r.id))
        resetStroke()
    }

    private fun emitFinished(r: Rec) {
        channel.invokeMethod(
            "strokeFinished",
            mapOf(
                "id" to r.id,
                "family" to r.family,
                "argb" to r.argb,
                "sizePx" to r.sizePx.toDouble(),
                "points" to r.array()
            )
        )
    }

    private fun resetStroke() {
        penPointerId = -1
        current = null
        rec = null
        limiter.reset()
    }
}
''';
