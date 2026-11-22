/// Kalem yüzeyi A uygulaması (Android yerel): Jetpack Ink (`androidx.ink`) ile
/// düşük gecikmeli çizim, `androidx.input` ile hareket tahmini. Flutter'a
/// PlatformView olarak (`kocum/ink_surface`) gömülür. Fonksiyonlar saf metin
/// dönüşümleridir ve idempotenttir; test/ink_patch_test.dart ile denenir.
///
/// Lisanslar: androidx.ink ve androidx.input Apache-2.0.
library;

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
  final deps = inkDependencies.map((d) => '    implementation("$d")').join('\n');
  return '$s\n// $inkMarker: Jetpack Ink + hareket tahmini\ndependencies {\n$deps\n}\n';
}

/// app/build.gradle (Groovy).
String patchInkGroovy(String s) {
  if (s.contains(inkMarker)) return s;
  final deps = inkDependencies.map((d) => "    implementation '$d'").join('\n');
  return "$s\n// $inkMarker: Jetpack Ink + hareket tahmini\ndependencies {\n$deps\n}\n";
}

const inkProguardMarker = '# kocum-ink-r8';

const inkProguardRules = '''
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
    RegExp(r'^([ \t]*)super\.configureFlutterEngine\(flutterEngine\)[ \t]*$', multiLine: true),
    (m) => '${m[0]}\n${m[1]}$inkRegisterCall',
  );
}

/// Fabrika, kayıt nesnesi ve çizim görünümü (tek Kotlin dosyası).
/// Not: Dart `'''` dizgesi; Kotlin dizge şablonu ($) KULLANILMAZ.
String inkKotlin(String package) => '''
package $package

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.util.Log
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.brush.StockBrushes
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.strokes.Stroke
import androidx.input.motionprediction.MotionEventPredictor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

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

/// Dokunuşu onTouchEvent'inde alır: yalnızca kalem çizer; parmak ve avuç yok sayılır
/// (çizilmez, Dart'a gönderilmez). DİKKAT: AndroidView dokunuşu Dart üzerinden yerele
/// SENTETİK olay olarak iletir; burada false dönmek olayı Flutter'a iade ETMEZ, bu yüzden
/// hep true döneriz. Parmakla kaydırma/yakınlaştırmayı Dart tarafı AndroidView üstünde
/// kendisi yönetir. requestUnbufferedDispatch sentetik olayda etkisiz olabilir; A'nın
/// girişine bir Dart gidiş-dönüşü eklenir (ölçüm notuna bakın).
/// Koordinatlar Flutter'ın mantıksal pikselidir (fiziksel px / yoğunluk).
class KocumInkView(
    context: Context,
    private val channel: MethodChannel,
    private var tool: String,
    private var color: Int,
    private var widthLogical: Float
) : FrameLayout(context) {
    var stylusOnly = true

    private val density = resources.displayMetrics.density
    private val identity = Matrix()
    private val renderer = CanvasStrokeRenderer.create()
    private val finished = ArrayList<Stroke>()
    private val predictor = MotionEventPredictor.newInstance(this)

    private val layer = object : View(context) {
        override fun onDraw(canvas: Canvas) {
            for (s in finished) renderer.draw(canvas, s, identity)
        }
    }
    private val ink = InProgressStrokesView(context)

    private var brush = makeBrush()
    private var activePointer = -1
    private var activeInk: InProgressStrokeId? = null
    private var nextId = 0
    private var activeId = 0

    // Gecikme ölçümü "A giris->vsync": olayın eventTime'ı (uptimeMillis) ile onu işleyen
    // ilk Choreographer karesinin başlangıcı (frameTimeNanos, aynı saat) farkı. Dart tarafı
    // B için hem "giris->vsync" hem "giris->raster" yazar; A yalnız vsync'e kadar ölçer.
    // Ink'in ön tampon çizimi sonrası ölçüm YOKTUR: ekrana ulaşma süresi ölçülmüyor.
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
        addView(ink, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        ink.addFinishedStrokesListener(object : InProgressStrokesFinishedListener {
            override fun onStrokesFinished(strokes: Map<InProgressStrokeId, Stroke>) {
                finished.addAll(strokes.values)
                ink.removeFinishedStrokes(strokes.keys)
                layer.invalidate()
            }
        })
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

    fun clearAll() {
        ink.cancelUnfinishedStrokes()
        activePointer = -1
        activeInk = null
        finished.clear()
        layer.invalidate()
    }

    fun release() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        ink.cancelUnfinishedStrokes()
    }

    private fun accepts(e: MotionEvent, index: Int): Boolean =
        e.getToolType(index) == MotionEvent.TOOL_TYPE_STYLUS || !stylusOnly

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
            "x" to (x / density).toDouble(),
            "y" to (y / density).toDouble(),
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

    private fun startStroke(e: MotionEvent, index: Int) {
        requestUnbufferedDispatch(e)
        activePointer = e.getPointerId(index)
        activeId = nextId++
        predictor.record(e)
        if (tool != "eraser") {
            activeInk = ink.startStroke(e, activePointer, brush, identity, identity)
        }
        stampLatency(e)
        emit("strokeStart", e, index, -1)
    }

    private fun endStroke(e: MotionEvent, index: Int) {
        predictor.record(e)
        val id = activeInk
        if (id != null) ink.finishStroke(e, activePointer, id)
        emit("strokeEnd", e, index, -1)
        activePointer = -1
        activeInk = null
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
                val id = activeInk
                if (id != null) {
                    val predicted = predictor.predict()
                    ink.addToStroke(e, activePointer, id, predicted)
                    predicted?.recycle()
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
                    val id = activeInk
                    if (id != null) ink.cancelStroke(id, e)
                    channel.invokeMethod("strokeCancel", mapOf("id" to activeId))
                    activePointer = -1
                    activeInk = null
                }
                return true
            }
        }
        return true
    }
}
''';
