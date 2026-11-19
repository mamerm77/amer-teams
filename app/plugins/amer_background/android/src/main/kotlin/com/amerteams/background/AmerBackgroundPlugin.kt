package com.amerteams.background

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit

/** Background blur and low-light correction on the local camera track, before encoding and encryption. */
class AmerBackgroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val active = HashMap<String, BlurProcessor>()

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(b.binaryMessenger, "com.amerteams/background"); channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) { channel.setMethodCallHandler(null) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "apply") { result.notImplemented(); return }
        val id = call.argument<String>("trackId") ?: return result.success(false)
        val blur = call.argument<Int>("blur") ?: 0; val low = call.argument<Boolean>("lowLight") ?: false
        val track = FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(id) as? LocalVideoTrack ?: return result.success(false)
        active.remove(id)?.let { track.removeProcessor(it); it.close() }
        if (blur > 0 || low) { val p = BlurProcessor(blur, low); track.addProcessor(p); active[id] = p }
        result.success(true)
    }
}

/** One frame: I420 -> ARGB -> person mask (ML Kit) -> blurred background + sharp person -> I420. */
class BlurProcessor(private val radius: Int, private val lowLight: Boolean) : LocalVideoTrack.ExternalVideoFrameProcessing {
    private val segmenter = Segmentation.getClient(SelfieSegmenterOptions.Builder()
        .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE).enableRawSizeMask().build())
    fun close() = segmenter.close()

    override fun onFrame(frame: VideoFrame): VideoFrame {
        return try { process(frame) } catch (e: Throwable) { frame }   // never drop video because of an effect
    }

    private fun process(frame: VideoFrame): VideoFrame {
        val i420 = frame.buffer.toI420() ?: return frame
        val w = i420.width; val h = i420.height
        val argb = IntArray(w * h)
        yuvToArgb(i420, argb, w, h); i420.release()
        val src = Bitmap.createBitmap(argb, w, h, Bitmap.Config.ARGB_8888)
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        if (lowLight) brighten(out)
        if (radius > 0) {
            val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(src, 0)), 200, TimeUnit.MILLISECONDS)
            val bg = cheapBlur(out, radius)
            composite(out, bg, mask)
        }
        val res = argbToI420(out, w, h)
        src.recycle(); out.recycle()
        return VideoFrame(res, frame.rotation, frame.timestampNs)
    }

    private fun brighten(b: Bitmap) {
        val c = Canvas(b); val p = Paint()
        p.colorFilter = ColorMatrixColorFilter(ColorMatrix(floatArrayOf(1.35f, 0f, 0f, 0f, 18f, 0f, 1.35f, 0f, 0f, 18f, 0f, 0f, 1.35f, 0f, 18f, 0f, 0f, 0f, 1f, 0f)))
        c.drawBitmap(b.copy(Bitmap.Config.ARGB_8888, false), 0f, 0f, p)
    }

    /** Down-scale then up-scale with filtering: a fast, wide blur suited to backgrounds. */
    private fun cheapBlur(b: Bitmap, r: Int): Bitmap {
        val f = (r.coerceIn(1, 25) + 3)
        val small = Bitmap.createScaledBitmap(b, maxOf(1, b.width / f), maxOf(1, b.height / f), true)
        val back = Bitmap.createScaledBitmap(small, b.width, b.height, true); small.recycle(); return back
    }

    private fun composite(out: Bitmap, bg: Bitmap, m: SegmentationMask) {
        val w = out.width; val h = out.height; val mw = m.width; val mh = m.height
        val buf: ByteBuffer = m.buffer; buf.rewind()
        val conf = FloatArray(mw * mh); buf.asFloatBuffer().get(conf)
        val fg = IntArray(w * h); val bgPx = IntArray(w * h)
        out.getPixels(fg, 0, w, 0, 0, w, h); bg.getPixels(bgPx, 0, w, 0, 0, w, h)
        for (y in 0 until h) { val my = y * mh / h
            for (x in 0 until w) { val a = conf[my * mw + x * mw / w]; val i = y * w + x
                if (a < 0.98f) { val p = fg[i]; val q = bgPx[i]
                    fg[i] = Color.rgb((Color.red(p) * a + Color.red(q) * (1 - a)).toInt(), (Color.green(p) * a + Color.green(q) * (1 - a)).toInt(), (Color.blue(p) * a + Color.blue(q) * (1 - a)).toInt()) } } }
        out.setPixels(fg, 0, w, 0, 0, w, h); bg.recycle()
    }

    private fun yuvToArgb(b: VideoFrame.I420Buffer, out: IntArray, w: Int, h: Int) {
        val y = b.dataY; val u = b.dataU; val v = b.dataV; val sy = b.strideY; val su = b.strideU; val sv = b.strideV
        for (j in 0 until h) for (i in 0 until w) {
            val yy = (y.get(j * sy + i).toInt() and 0xff) - 16; val uu = (u.get((j / 2) * su + i / 2).toInt() and 0xff) - 128; val vv = (v.get((j / 2) * sv + i / 2).toInt() and 0xff) - 128
            val r = (1.164f * yy + 1.596f * vv).toInt().coerceIn(0, 255); val g = (1.164f * yy - 0.392f * uu - 0.813f * vv).toInt().coerceIn(0, 255); val bl = (1.164f * yy + 2.017f * uu).toInt().coerceIn(0, 255)
            out[j * w + i] = Color.rgb(r, g, bl)
        }
    }

    private fun argbToI420(b: Bitmap, w: Int, h: Int): JavaI420Buffer {
        val px = IntArray(w * h); b.getPixels(px, 0, w, 0, 0, w, h)
        val buf = JavaI420Buffer.allocate(w, h)
        val y = buf.dataY; val u = buf.dataU; val v = buf.dataV
        for (j in 0 until h) for (i in 0 until w) {
            val c = px[j * w + i]; val r = Color.red(c); val g = Color.green(c); val bl = Color.blue(c)
            y.put(j * buf.strideY + i, ((66 * r + 129 * g + 25 * bl + 128 shr 8) + 16).toByte())
            if (j % 2 == 0 && i % 2 == 0) {
                u.put((j / 2) * buf.strideU + i / 2, ((-38 * r - 74 * g + 112 * bl + 128 shr 8) + 128).toByte())
                v.put((j / 2) * buf.strideV + i / 2, ((112 * r - 94 * g - 18 * bl + 128 shr 8) + 128).toByte())
            }
        }
        return buf
    }
}
