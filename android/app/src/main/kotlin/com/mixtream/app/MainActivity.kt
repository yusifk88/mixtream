package com.mixtream.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.Manifest
import android.util.Log
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.MediaStore
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.nio.ByteBuffer
import java.util.HashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.view.TextureRegistry.SurfaceTextureEntry
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val RECORD_AUDIO_REQUEST_CODE = 2001
        private const val SAVE_NOTIFICATION_ID = 1001
        private const val SAVE_CHANNEL_ID = "mixstream_save"
        private const val PIP_CORNER_RADIUS = 14f
        private const val PIP_SHADOW_RADIUS = 12f
        private const val PIP_SHADOW_DX = 3f
        private const val PIP_SHADOW_DY = 7f
        private const val PIP_SHADOW_ALPHA = 70
    }

    private var flutterEngineRef: FlutterEngine? = null
    private var previewTextureEntry: SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var saveNotifManager: NotificationManager? = null

    // ─── PiP preview ──────────────────
    private var pipCameraDevice: CameraDevice? = null
    private var pipCaptureSession: CameraCaptureSession? = null
    private var pipImageReader: ImageReader? = null
    private var pipBgThread: HandlerThread? = null
    private var pipBgHandler: Handler? = null
    private var pipEventSink: EventChannel.EventSink? = null

    // ─── Recording mixer state ───────────────────
    private var mainCameraDevice: CameraDevice? = null
    private var recPipCameraDevice: CameraDevice? = null
    private var mainImageReader: ImageReader? = null
    private var recPipImageReader: ImageReader? = null
    private var mainCaptureSession: CameraCaptureSession? = null
    private var recPipCaptureSession: CameraCaptureSession? = null
    private var recBgThread: HandlerThread? = null
    private var recBgHandler: Handler? = null
    private var encoderThread: HandlerThread? = null
    private var encoderHandler: Handler? = null

    private var mediaCodec: MediaCodec? = null
    private var mediaMuxer: MediaMuxer? = null
    private var encoderSurface: Surface? = null
    private var videoTrackIndex = -1
    @Volatile
    private var isRecording = false
    @Volatile
    private var isEncoderDone = false
    @Volatile
    private var compositeFinished = false
    private var outputPath: String? = null
    private var firstVideoPtsUs: Long = -1L

    // Audio capture
    private var audioRecord: AudioRecord? = null
    private var audioEncoder: MediaCodec? = null
    private var audioCaptureThread: HandlerThread? = null
    private var audioCaptureHandler: Handler? = null
    @Volatile
    private var audioTrackIndex = -1
    private var audioBufferInfo: MediaCodec.BufferInfo? = null

    // A/V sync: record real timestamps so audio PTS aligns with video start
    private var audioStartRealtimeNs: Long = 0L
    private var videoFirstFrameRealtimeNs: Long = -1L
    @Volatile
    private var videoFirstFrameReady = false

    // Muxer sync (both video and audio tracks must be added before muxer.start())
    @Volatile
    private var muxerStarted = false
    private var videoFormatReady = false
    private var audioFormatReady = false
    private var previewSink: EventChannel.EventSink? = null
    private var pipPreviewSink: EventChannel.EventSink? = null
    private var pipPreviewFrameCount = 0
    private var frameLock = ReentrantLock()
    private val muxerLock = Any()

    // Dedicated thread for compositing (keeps camera callbacks unblocked)
    private var compositeThread: HandlerThread? = null
    private var compositeHandler: Handler? = null

    private var latestMainRgba: ByteArray? = null
    private var latestPipRgba: ByteArray? = null
    private var latestPipW = 0
    private var latestPipH = 0

    private var compositeBitmap: Bitmap? = null
    private var pipBitmap: Bitmap? = null
    private var pipShadowPaint: Paint? = null
    private var reuseMainRgba: ByteArray? = null
    private var previewFrameCount = 0

    // Last known PiP frame — reused when no new pip image arrives (prevents flickering)
    private var lastPipRgba: ByteArray? = null
    private var lastPipW = 0
    private var lastPipH = 0

    // PiP config
    private var pipNormX = 0.82
    private var pipNormY = 0.11
    private var pipNormW = 0.17
    private var pipNormH = 0.22
    private var useMainFront = false
    private var pipNeedsMirror = true
    private var pipEnabled = true
    private var pipCornerRadius = 14f
    private var pipShadowAlpha = 70
    private var pipZoom = 1.0f
    private var mainCameraRotation = 0
    private var pipCameraRotation = 0

    // Photo overlay config (multi-photo)
    private data class PhotoOverlay(
        val id: String = "",
        val bitmap: Bitmap,
        var normX: Double,
        var normY: Double,
        var normW: Double,
        var normH: Double
    )
    private val photoOverlays = mutableListOf<PhotoOverlay>()

    private fun decodeBitmapSafe(data: ByteArray): Bitmap? {
        return try {
            val opts = BitmapFactory.Options()
            opts.inJustDecodeBounds = true
            BitmapFactory.decodeByteArray(data, 0, data.size, opts)
            val maxDim = 4096
            if (opts.outWidth > maxDim || opts.outHeight > maxDim) {
                val scale = maxOf(opts.outWidth, opts.outHeight) / maxDim
                opts.inSampleSize = Integer.highestOneBit(scale.coerceAtLeast(1))
            }
            opts.inJustDecodeBounds = false
            BitmapFactory.decodeByteArray(data, 0, data.size, opts)
        } catch (e: Exception) {
            Log.e("Mixer", "Failed to decode bitmap: ${e.message}")
            null
        }
    }

    private val OUT_W = 720
    private val OUT_H = 1280
    private val PREVIEW_W = 320
    private val PREVIEW_H = 480
    private val BITRATE = 8_000_000

    // Preview texture surface size (half of output)
    private val PREVIEW_TEX_W = 360
    private val PREVIEW_TEX_H = 640

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngineRef = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.learningflutter/pip_camera")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val w = (call.argument<Int>("width") ?: 320).coerceIn(160, 1280)
                        val h = (call.argument<Int>("height") ?: 240).coerceIn(120, 960)
                        val front = call.argument<Boolean>("frontCamera") ?: true
                        startPipPreview(w, h, front)
                        result.success(true)
                    }
                    "stop" -> { stopPipPreview(); result.success(true) }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.learningflutter/pip_frames")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink) { pipEventSink = s }
                override fun onCancel(a: Any?) { pipEventSink = null }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.learningflutter/video_mixer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        val args = call.arguments as? Map<String, Any> ?: emptyMap()
                        startMixer(args, result)
                    }
                    "stopRecording" -> {
                        val path = stopMixer()
                        result.success(path)
                    }
                    "addPhoto" -> {
                        val id = call.argument<String>("id") ?: ""
                        val data = call.argument<ByteArray>("data")
                        val normX = call.argument<Double>("normX") ?: 0.0
                        val normY = call.argument<Double>("normY") ?: 0.0
                        val normW = call.argument<Double>("normW") ?: 0.0
                        val normH = call.argument<Double>("normH") ?: 0.0
                        if (data != null) {
                            val bmp = decodeBitmapSafe(data)
                            if (bmp != null) {
                                photoOverlays.add(PhotoOverlay(
                                    id = id, bitmap = bmp,
                                    normX = normX, normY = normY,
                                    normW = normW, normH = normH,
                                ))
                                Log.d("Mixer", "addPhoto: $id (${photoOverlays.size} total)")
                            }
                        }
                        result.success(true)
                    }
                    "updatePipZoom" -> {
                        val zoom = (call.argument<Double>("zoom") ?: 1.0).toFloat()
                        pipZoom = zoom.coerceAtLeast(1f)
                        result.success(true)
                    }
                    "updatePipConfig" -> {
                        pipNormX = (call.argument<Double>("pipNormX") ?: pipNormX)
                        pipNormY = (call.argument<Double>("pipNormY") ?: pipNormY)
                        pipNormW = (call.argument<Double>("pipNormW") ?: pipNormW)
                        pipNormH = (call.argument<Double>("pipNormH") ?: pipNormH)
                        pipCornerRadius = (call.argument<Double>("pipCornerRadius") ?: pipCornerRadius.toDouble()).toFloat()
                        pipShadowAlpha = (call.argument<Int>("pipShadowAlpha") ?: pipShadowAlpha)
                        pipZoom = (call.argument<Double>("pipZoom") ?: pipZoom.toDouble()).toFloat().coerceAtLeast(1f)
                        pipEnabled = (call.argument<Boolean>("pipEnabled") ?: pipEnabled)
                        // Multi-photo: update positions by ID, reuse bitmaps
                        val rawPhotos = call.argument<List<*>>("photos")
                        if (rawPhotos != null) {
                            val newOverlays = mutableListOf<PhotoOverlay>()
                            val oldById = photoOverlays.associateBy { it.id }
                            for (item in rawPhotos) {
                                @Suppress("UNCHECKED_CAST")
                                val p = item as? Map<String, Any> ?: continue
                                val id = p["id"] as? String ?: ""
                                val existing = oldById[id]
                                if (existing != null) {
                                    newOverlays.add(PhotoOverlay(
                                        id = id,
                                        bitmap = existing.bitmap,
                                        normX = (p["normX"] as? Double) ?: 0.0,
                                        normY = (p["normY"] as? Double) ?: 0.0,
                                        normW = (p["normW"] as? Double) ?: 0.0,
                                        normH = (p["normH"] as? Double) ?: 0.0,
                                    ))
                                }
                            }
                            // Recycle bitmaps for removed photos
                            val newIds = newOverlays.map { it.id }.toSet()
                            for (old in photoOverlays) {
                                if (old.id !in newIds) old.bitmap.recycle()
                            }
                            photoOverlays.clear()
                            photoOverlays.addAll(newOverlays)
                            Log.d("Mixer", "updatePipConfig: ${photoOverlays.size} photos (bitmaps reused)")
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.learningflutter/mixer_preview")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink) { previewSink = s }
                override fun onCancel(a: Any?) { previewSink = null }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.learningflutter/mixer_pip_preview")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, s: EventChannel.EventSink) { pipPreviewSink = s }
                override fun onCancel(a: Any?) { pipPreviewSink = null }
            })
    }

    // ══════════════════════════════════════════════
    //  PiP PREVIEW
    // ══════════════════════════════════════════════

    private fun startPipPreview(width: Int, height: Int, front: Boolean) {
        if (pipCameraDevice != null) return
        pipBgThread = HandlerThread("PipPreview").also { it.start() }
        pipBgHandler = Handler(pipBgThread!!.looper)
        val mgr = getSystemService(CAMERA_SERVICE) as CameraManager
        val target = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val camId = findCameraId(mgr, target) ?: run { pipEventSink?.error("NO_CAMERA", "No PiP camera", null); return }
        val chars = mgr.getCameraCharacteristics(camId)
        val rot = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val (rw, rh) = if (rot == 90 || rot == 270) Pair(height, width) else Pair(width, height)

        pipImageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2).apply {
            setOnImageAvailableListener({ r ->
                val img = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                val rgba = YuvConverter.yuvToRgba(img, rw, rh, rot, mirror = true)
                img.close()
                val map = HashMap<String, Any?>()
                map["width"] = rw; map["height"] = rh; map["pixels"] = rgba
                Handler(Looper.getMainLooper()).post { pipEventSink?.success(map) }
            }, pipBgHandler)
        }

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(c: CameraDevice) {
                pipCameraDevice = c
                val surf = pipImageReader!!.surface
                val req = c.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(surf) }
                c.createCaptureSession(listOf(surf), objSessionCb({
                    pipCaptureSession = it; it.setRepeatingRequest(req.build(), null, pipBgHandler)
                }, { pipEventSink?.error("CONF_FAIL", "PiP config fail", null) }), pipBgHandler)
            }
            override fun onDisconnected(c: CameraDevice) { c.close(); pipCameraDevice = null }
            override fun onError(c: CameraDevice, e: Int) { c.close(); pipCameraDevice = null; pipEventSink?.error("CAM_ERR", "PiP error $e", null) }
        }, pipBgHandler)
    }

    private fun stopPipPreview() {
        try {
            pipCaptureSession?.close(); pipCaptureSession = null
            pipCameraDevice?.close(); pipCameraDevice = null
            pipImageReader?.close(); pipImageReader = null
            pipBgThread?.quitSafely(); pipBgThread = null; pipBgHandler = null
        } catch (_: Exception) {}
    }

    // ══════════════════════════════════════════════
    //  VIDEO MIXER
    // ══════════════════════════════════════════════

    private fun startMixer(args: Map<String, Any>, result: MethodChannel.Result) {
        if (isRecording) { result.success(true); return }

        // Release PiP preview camera before opening recording cameras (same camera may conflict)
        stopPipPreview()

        pipNormX = (args["pipNormX"] as? Double) ?: 0.82
        pipNormY = (args["pipNormY"] as? Double) ?: 0.11
        pipNormW = (args["pipNormW"] as? Double) ?: 0.17
        pipNormH = (args["pipNormH"] as? Double) ?: 0.22
        useMainFront = (args["useMainFront"] as? Boolean) ?: false
        pipEnabled = (args["pipEnabled"] as? Boolean) ?: true
        pipCornerRadius = (args["pipCornerRadius"] as? Double)?.toFloat() ?: 14f
        pipShadowAlpha = (args["pipShadowAlpha"] as? Int) ?: 70
        pipZoom = (args["pipZoom"] as? Double)?.toFloat() ?: 1.0f
        pipNeedsMirror = !useMainFront

        // Photo overlays (multi-photo)
        photoOverlays.clear()
        val photosArg = args["photos"] as? List<*>
        if (photosArg != null) {
            for (item in photosArg) {
                val p = item as? Map<*, *> ?: continue
                val id = (p["id"] as? String) ?: ""
                val data = p["data"] as? ByteArray ?: continue
                val bmp = decodeBitmapSafe(data) ?: continue
                photoOverlays.add(PhotoOverlay(
                    id = id,
                    bitmap = bmp,
                    normX = (p["normX"] as? Double) ?: 0.0,
                    normY = (p["normY"] as? Double) ?: 0.0,
                    normW = (p["normW"] as? Double) ?: 0.0,
                    normH = (p["normH"] as? Double) ?: 0.0,
                ))
            }
        }

        // Reset muxer state flags for fresh recording
        videoFormatReady = false
        audioFormatReady = false

        recBgThread = HandlerThread("MixerCapture").also { it.start() }
        recBgHandler = Handler(recBgThread!!.looper)
        encoderThread = HandlerThread("MixerEncode").also { it.start() }
        encoderHandler = Handler(encoderThread!!.looper)
        compositeThread = HandlerThread("MixerComposite").also { it.start() }
        compositeHandler = Handler(compositeThread!!.looper)
        isEncoderDone = false
        compositeFinished = false
        videoFirstFrameRealtimeNs = -1L
        videoFirstFrameReady = false

        val mgr = getSystemService(CAMERA_SERVICE) as CameraManager

        val mainId: String?
        val pipId: String?
        if (useMainFront) {
            mainId = findFirstFrontFacing(mgr)
            pipId = findFirstBackFacing(mgr)
        } else {
            mainId = findFirstBackFacing(mgr)
            pipId = findFirstFrontFacing(mgr)
        }

        if (mainId == null) { result.error("NO_MAIN", "No main camera", null); return }

        outputPath = File(cacheDir, "MixStream_${System.currentTimeMillis()}.mp4").absolutePath

        // Preview SurfaceTexture for Flutter Texture widget
        previewTextureEntry = flutterEngineRef?.renderer?.createSurfaceTexture()
        previewTextureEntry?.surfaceTexture()?.setDefaultBufferSize(PREVIEW_TEX_W, PREVIEW_TEX_H)
        previewSurface = previewTextureEntry?.surfaceTexture()?.let { Surface(it) }

        compositeBitmap?.recycle()
        compositeBitmap = Bitmap.createBitmap(OUT_W, OUT_H, Bitmap.Config.ARGB_8888)
        val initPipW = (pipNormW * OUT_W).toInt().coerceIn(8, OUT_W)
        val initPipH = (pipNormH * OUT_H).toInt().coerceIn(8, OUT_H)
        pipBitmap?.recycle()
        pipBitmap = Bitmap.createBitmap(initPipW, initPipH, Bitmap.Config.ARGB_8888)
        pipShadowPaint = Paint()

        isRecording = true

        setupEncoder(OUT_W, OUT_H)
        startAudioCapture()

        // Open cameras — convert YUV→RGBA in callback and close Image immediately to avoid buffer exhaustion
        openMixerCamera(mgr, mainId, true, OUT_W, OUT_H) { img ->
            val rgba = YuvConverter.yuvToRgba(img, OUT_W, OUT_H, mainCameraRotation, mirror = useMainFront, reuseOut = reuseMainRgba)
            reuseMainRgba = ByteArray(OUT_W * OUT_H * 4)
            img.close()
            frameLock.withLock { latestMainRgba = rgba }
            compositeHandler?.post { tryComposite() }
        }

        if (pipId != null) {
            openMixerCamera(mgr, pipId, false, OUT_W, OUT_H) { img ->
                val pw = (pipNormW * OUT_W).toInt().coerceIn(8, OUT_W)
                val ph = (pipNormH * OUT_H).toInt().coerceIn(8, OUT_H)
                val rgba = YuvConverter.yuvToRgba(img, pw, ph, pipCameraRotation, mirror = pipNeedsMirror)
                img.close()
                frameLock.withLock {
                    latestPipRgba = rgba
                    latestPipW = pw
                    latestPipH = ph
                }
            }
        }

        previewFrameCount = 0
        pipPreviewFrameCount = 0

        val res = HashMap<String, Any>()
        res["textureId"] = previewTextureEntry?.id() ?: -1L
        result.success(res)
    }

    private fun stopMixer(): String? {
        isRecording = false
        try {
            // Stop camera pipeline first (no more frames to encoder)
            frameLock.withLock {
                latestMainRgba = null
                latestPipRgba = null; latestPipW = 0; latestPipH = 0
                lastPipRgba = null; lastPipW = 0; lastPipH = 0
            }
            mainCaptureSession?.close(); mainCaptureSession = null
            mainCameraDevice?.close(); mainCameraDevice = null
            recPipCaptureSession?.close(); recPipCaptureSession = null
            recPipCameraDevice?.close(); recPipCameraDevice = null
            mainImageReader?.close(); mainImageReader = null
            recPipImageReader?.close(); recPipImageReader = null
            recBgThread?.quitSafely(); recBgThread = null; recBgHandler = null

            // Stop composite thread — drain all pending frames to encoder Surface
            compositeThread?.quitSafely()
            compositeThread?.join(2000)
            compositeThread = null; compositeHandler = null

            // Signal encoder loop that no more frames will be composited
            compositeFinished = true

            // Wait for encoder loop to exit (encoder drains all queued frames)
            val deadline = System.currentTimeMillis() + 5000
            while (!isEncoderDone && System.currentTimeMillis() < deadline) {
                Thread.sleep(50)
            }

            // Reset PTS timestamps now that encoder loop is fully done
            firstVideoPtsUs = -1L
            videoFirstFrameRealtimeNs = -1L
            videoFirstFrameReady = false
            audioStartRealtimeNs = 0L

            // Signal the audio thread to stop (encoder is done, audio can be safely stopped)
            audioCaptureThread?.quitSafely()
            audioCaptureThread?.join(2000)
            audioCaptureThread = null; audioCaptureHandler = null
            audioEncoder = null; audioTrackIndex = -1

            // Stop muxer on main thread (after encoder is fully done)
            synchronized(muxerLock) {
                if (muxerStarted) {
                    try {
                        mediaMuxer?.stop()
                    } catch (e: Exception) {
                        Log.e("Mixer", "muxer stop failed: ${e.message}")
                    }
                }
                try { mediaMuxer?.release() } catch (_: Exception) {}
                mediaMuxer = null; muxerStarted = false; videoTrackIndex = -1
                videoFormatReady = false; audioFormatReady = false
            }

            encoderThread?.quitSafely()
            try { encoderThread?.join(2000) } catch (_: Exception) {}
            encoderThread = null; encoderHandler = null

            compositeBitmap?.recycle(); compositeBitmap = null
            pipBitmap?.recycle(); pipBitmap = null
            for (po in photoOverlays) { po.bitmap.recycle() }
            photoOverlays.clear()

            previewSurface = null
            previewTextureEntry?.release()
            previewTextureEntry = null

            val path = outputPath
            if (path != null) {
                val file = File(path)
                if (file.exists() && file.length() > 4096) {
                    val intent = Intent(this, SaveVideoService::class.java).putExtra("file_path", path)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                } else {
                    Log.e("Mixer", "video file too small or missing, deleting")
                    file.delete()
                }
            }
        } catch (_: Exception) {}
        return outputPath
    }

    private fun saveVideoToGallery(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) return
        val fileName = "MixStream_${System.currentTimeMillis()}.mp4"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES)
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }
        val uri = contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
        if (uri != null) {
            try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { inp -> inp.copyTo(out) }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    values.clear()
                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                }
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
            }
        }
    }

    // ── Encoder setup ──

    private fun setupEncoder(w: Int, h: Int) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        mediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = createInputSurface()
            start()
        }

        mediaMuxer = MediaMuxer(outputPath!!, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        videoTrackIndex = -1

            encoderHandler!!.post {
            val bufferInfo = MediaCodec.BufferInfo()
            var videoFramesWritten = 0
            while (!isEncoderDone) {
                val idx = mediaCodec!!.dequeueOutputBuffer(bufferInfo, 100_000L)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (compositeFinished) {
                            // All frames have been composited; encoder got everything
                            break
                        }
                    }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        synchronized(muxerLock) {
                            if (videoTrackIndex < 0) {
                                videoTrackIndex = mediaMuxer!!.addTrack(mediaCodec!!.outputFormat)
                                videoFormatReady = true
                                Log.d("VideoEncoder", "video track added, idx=$videoTrackIndex")
                                tryStartMuxer()
                            }
                        }
                    }
                    idx >= 0 -> {
                        val isEos = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        val isConfig = bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (isConfig) { bufferInfo.size = 0 }
                        if (isEos) { break }
                        if (bufferInfo.size > 0) {
                            if (firstVideoPtsUs < 0) {
                                firstVideoPtsUs = bufferInfo.presentationTimeUs
                                Log.d("VideoEncoder", "first frame raw PTS=$firstVideoPtsUs")
                            }
                            val avOffsetUs = if (videoFirstFrameRealtimeNs > 0 && audioStartRealtimeNs > 0) {
                                (videoFirstFrameRealtimeNs - audioStartRealtimeNs) / 1000
                            } else { 0L }
                            bufferInfo.presentationTimeUs = (bufferInfo.presentationTimeUs - firstVideoPtsUs) + avOffsetUs
                        }
                        if (bufferInfo.size > 0 && videoTrackIndex >= 0 && muxerStarted) {
                            val buf = mediaCodec!!.getOutputBuffer(idx)!!
                            buf.position(bufferInfo.offset)
                            buf.limit(bufferInfo.offset + bufferInfo.size)
                            try {
                                synchronized(muxerLock) {
                                    if (muxerStarted) {
                                        mediaMuxer!!.writeSampleData(videoTrackIndex, buf, bufferInfo)
                                    }
                                }
                                videoFramesWritten++
                                if (videoFramesWritten % 30 == 1) {
                                    Log.d("VideoEncoder", "$videoFramesWritten frames written, pts=${bufferInfo.presentationTimeUs}")
                                }
                            } catch (_: IllegalStateException) {
                                // race during shutdown
                            }
                        }
                        mediaCodec!!.releaseOutputBuffer(idx, false)
                    }
                }
            }
            try {
                mediaCodec?.stop(); mediaCodec?.release(); mediaCodec = null
            } catch (_: Exception) {}
            Log.d("VideoEncoder", "codec stopped, muxerStarted=$muxerStarted, framesWritten=$videoFramesWritten")
            isEncoderDone = true
        }
    }

    private fun tryStartMuxer() {
        synchronized(muxerLock) {
            if (!muxerStarted && videoFormatReady && audioFormatReady) {
                mediaMuxer!!.start()
                muxerStarted = true
                Log.d("Muxer", "started (video=$videoTrackIndex, audio=$audioTrackIndex)")
            } else {
                Log.d("Muxer", "waiting: muxerStarted=$muxerStarted video=$videoFormatReady audio=$audioFormatReady")
            }
        }
    }

    // ── Audio capture ──

    private fun startAudioCapture() {
        // Skip audio if permission not granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            Log.w("AudioCapture", "RECORD_AUDIO permission not granted — skipping audio")
            audioFormatReady = true
            tryStartMuxer()
            return
        }

        val sampleRate = 44100
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioEncFmt = AudioFormat.ENCODING_PCM_16BIT
        val minBufSize = try {
            AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioEncFmt).coerceAtLeast(4096)
        } catch (_: Exception) { 4096 }
        Log.d("AudioCapture", "minBufSize=$minBufSize")

        audioRecord = try {
            AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig, audioEncFmt, minBufSize)
        } catch (e: Exception) {
            Log.e("AudioCapture", "AudioRecord creation failed", e); null
        }
        if (audioRecord == null || audioRecord!!.state != AudioRecord.STATE_INITIALIZED) {
            Log.w("AudioCapture", "AudioRecord not initialized (state=${audioRecord?.state}) — skipping audio")
            audioRecord = null
            audioFormatReady = true
            tryStartMuxer()
            return
        }

        val aacFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, 128000)
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        }
        audioEncoder = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                configure(aacFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
        } catch (e: Exception) {
            Log.e("AudioCapture", "AAC encoder creation failed", e); null
        }

        if (audioEncoder == null) {
            Log.w("AudioCapture", "AAC encoder is null — skipping audio")
            audioFormatReady = true
            tryStartMuxer()
            return
        }
        Log.d("AudioCapture", "AAC encoder started")

        audioTrackIndex = -1
        audioBufferInfo = MediaCodec.BufferInfo()

        audioCaptureThread = HandlerThread("AudioCapture").also { it.start() }
        audioCaptureHandler = Handler(audioCaptureThread!!.looper)

        audioCaptureHandler!!.post {
            try {
                Log.d("AudioCapture", "audio thread started")
                drainAudioEncoder()

                audioRecord!!.startRecording()
                audioStartRealtimeNs = System.nanoTime()
                Log.d("AudioCapture", "AudioRecord started")

                val pcmBuf = ByteArray(minBufSize)
                var ptsUs = 0L
                var frameCount = 0
                val aacFrameBytes = 2048
                val accBuf = ByteArray(aacFrameBytes)
                var accLen = 0

                while (isRecording && audioRecord != null) {
                    val bytesRead = try { audioRecord!!.read(pcmBuf, 0, minBufSize) } catch (_: Exception) { -1 }
                    if (bytesRead > 0) {
                        var off = 0
                        var rem = bytesRead
                        while (rem > 0) {
                            val take = minOf(rem, aacFrameBytes - accLen)
                            pcmBuf.copyInto(accBuf, accLen, off, off + take)
                            accLen += take
                            off += take
                            rem -= take

                            if (accLen >= aacFrameBytes) {
                                frameCount++
                                val inputIdx = audioEncoder!!.dequeueInputBuffer(0)
                                if (inputIdx >= 0) {
                                    val inputBuf = audioEncoder!!.getInputBuffer(inputIdx)!!
                                    inputBuf.clear()
                                    inputBuf.put(accBuf, 0, aacFrameBytes)
                                    audioEncoder!!.queueInputBuffer(inputIdx, 0, aacFrameBytes, ptsUs, 0)
                                    ptsUs += (aacFrameBytes / 2) * 1_000_000L / sampleRate
                                }
                                drainAudioEncoder()
                                accLen = 0
                            }
                        }
                    } else if (bytesRead < 0) {
                        Log.w("AudioCapture", "AudioRecord.read returned $bytesRead")
                    }
                }
                Log.d("AudioCapture", "loop exited, frames=$frameCount, isRecording=$isRecording, audioRecord=${audioRecord != null}")

                // Flush remaining partial frame
                if (accLen > 0) {
                    try {
                        val idx = audioEncoder!!.dequeueInputBuffer(1000)
                        if (idx >= 0) {
                            val buf = audioEncoder!!.getInputBuffer(idx)!!
                            buf.clear()
                            buf.put(accBuf, 0, accLen)
                            audioEncoder!!.queueInputBuffer(idx, 0, accLen, ptsUs, 0)
                        }
                    } catch (_: Exception) {}
                }

                // Signal EOS
                try {
                    val eosIdx = audioEncoder!!.dequeueInputBuffer(1000)
                    if (eosIdx >= 0) {
                        audioEncoder!!.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        Log.d("AudioCapture", "EOS queued")
                    }
                } catch (_: Exception) {}
                drainAudioEncoder()
                drainAudioEncoder()
                Log.d("AudioCapture", "encoder drained after EOS")

                try {
                    audioRecord?.stop(); audioRecord?.release(); audioRecord = null
                    Log.d("AudioCapture", "AudioRecord stopped/released")
                } catch (e: Exception) { Log.e("AudioCapture", "AudioRecord stop error", e) }

                try {
                    audioEncoder?.stop(); audioEncoder?.release(); audioEncoder = null
                    Log.d("AudioCapture", "AudioEncoder stopped/released")
                } catch (e: Exception) { Log.e("AudioCapture", "AudioEncoder stop error", e) }
            } catch (e: Exception) {
                Log.e("AudioCapture", "FATAL: audio thread crashed", e)
            }
        }
    }

    private fun drainAudioEncoder() {
        val enc = audioEncoder ?: return
        val bufInfo = audioBufferInfo ?: return
        while (true) {
            val idx = enc.dequeueOutputBuffer(bufInfo, 0)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        if (audioTrackIndex < 0) {
                            audioTrackIndex = mediaMuxer!!.addTrack(enc.outputFormat)
                            audioFormatReady = true
                            Log.d("AudioCapture", "track added, idx=$audioTrackIndex")
                            tryStartMuxer()
                        }
                    }
                }
                idx >= 0 -> {
                    if (bufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) { bufInfo.size = 0 }
                    val isEos = bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (bufInfo.size > 0 && audioTrackIndex >= 0 && muxerStarted) {
                        val buf = enc.getOutputBuffer(idx)!!
                        buf.position(bufInfo.offset)
                        buf.limit(bufInfo.offset + bufInfo.size)
                        try {
                            synchronized(muxerLock) {
                                if (muxerStarted) {
                                    mediaMuxer!!.writeSampleData(audioTrackIndex, buf, bufInfo)
                                }
                            }
                        } catch (_: IllegalStateException) {
                            // race: muxer already stopped during shutdown
                        }
                    }
                    enc.releaseOutputBuffer(idx, false)
                    if (isEos) break
                }
            }
        }
    }

    // ── Camera open helper ──

    private fun openMixerCamera(
        mgr: CameraManager, camId: String, isMain: Boolean,
        imgW: Int, imgH: Int, onFrame: (Image) -> Unit
    ) {
        val chars = mgr.getCameraCharacteristics(camId)
        val sensorRot = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        if (isMain) mainCameraRotation = sensorRot else pipCameraRotation = sensorRot

        // Swap ImageReader dimensions when sensor rotation is 90/270 so that
        // yuvToRgba with rotation reads within bounds (out-of-bounds occurs when
        // the rotation maps rows to columns but the source buffer is portrait).
        val (readerW, readerH) = if (sensorRot == 90 || sensorRot == 270)
            Pair(imgH, imgW) else Pair(imgW, imgH)

        val reader = ImageReader.newInstance(readerW, readerH, ImageFormat.YUV_420_888, 5).apply {
            setOnImageAvailableListener({ r ->
                val img = try { r.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
                onFrame(img)
            }, recBgHandler)
        }

        if (isMain) mainImageReader = reader else recPipImageReader = reader

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(c: CameraDevice) {
                if (isMain) mainCameraDevice = c else recPipCameraDevice = c
                val surf = reader.surface
                // Use PREVIEW for PiP camera to avoid RECORD-mode crop/VCEIS zoom on some devices
                val template = if (isMain) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
                val req = c.createCaptureRequest(template).apply { addTarget(surf) }
                c.createCaptureSession(listOf(surf), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        if (isMain) mainCaptureSession = s else recPipCaptureSession = s
                        s.setRepeatingRequest(req.build(), null, recBgHandler)
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) {}
                }, recBgHandler)
            }
            override fun onDisconnected(c: CameraDevice) { c.close() }
            override fun onError(c: CameraDevice, e: Int) { c.close() }
        }, recBgHandler)
    }

    // ── Frame compositing ──

    private var compositeFrameCount = 0

    private fun tryComposite() {
        // Extract RGBA bytes under lock (Images already closed in callbacks)
        val mainRgba: ByteArray?
        var newPipRgba: ByteArray? = null
        var newPipW = lastPipW
        var newPipH = lastPipH
        frameLock.withLock {
            mainRgba = latestMainRgba.also { latestMainRgba = null }
            if (latestPipRgba != null) {
                newPipRgba = latestPipRgba
                newPipW = latestPipW
                newPipH = latestPipH
                lastPipRgba = latestPipRgba
                lastPipW = latestPipW
                lastPipH = latestPipH
                latestPipRgba = null
            }
        }
        if (mainRgba == null) return

        val pipRgba = newPipRgba ?: lastPipRgba
        val pipTargetW = if (newPipRgba != null) newPipW else lastPipW
        val pipTargetH = if (newPipRgba != null) newPipH else lastPipH

        // A/V sync: record first video frame time
        if (videoFirstFrameRealtimeNs < 0) {
            videoFirstFrameRealtimeNs = System.nanoTime()
            videoFirstFrameReady = true
        }

        // Render to encoder surface
        val bmp = compositeBitmap
        val surface = encoderSurface
        if (bmp != null && surface != null && surface.isValid) {
            bmp.copyPixelsFromBuffer(ByteBuffer.wrap(mainRgba))
            var canvas: Canvas? = null
            try {
                canvas = surface.lockCanvas(null)
                if (canvas == null) { Log.w("Mixer", "lockCanvas null"); return }
                canvas.drawBitmap(bmp, 0f, 0f, null)

                if (pipEnabled && pipRgba != null && pipTargetW > 0 && pipTargetH > 0) {
                    val px = (pipNormX * OUT_W).toInt().coerceIn(0, OUT_W - pipTargetW)
                    val py = (pipNormY * OUT_H).toInt().coerceIn(0, OUT_H - pipTargetH)
                    var pipBmp = pipBitmap
                    if (pipBmp == null || pipBmp.width != pipTargetW || pipBmp.height != pipTargetH) {
                        pipBmp?.recycle()
                        pipBmp = Bitmap.createBitmap(pipTargetW, pipTargetH, Bitmap.Config.ARGB_8888)
                        pipBitmap = pipBmp
                    }
                    if (pipBmp != null) {
                        pipBmp.copyPixelsFromBuffer(ByteBuffer.wrap(pipRgba))

                        val l = px.toFloat(); val t = py.toFloat()
                        val r = (px + pipTargetW).toFloat(); val b2 = (py + pipTargetH).toFloat()
                        val r2 = pipCornerRadius.coerceIn(0f, 30f)
                        val sa = pipShadowAlpha.coerceIn(0, 255)
                        val zm = pipZoom.coerceAtLeast(1f)

                        val sp = pipShadowPaint!!
                        sp.color = Color.argb(sa, 0, 0, 0)
                        canvas.drawRoundRect(l + PIP_SHADOW_DX, t + PIP_SHADOW_DY,
                            r + PIP_SHADOW_DX, b2 + PIP_SHADOW_DY, r2, r2, sp)

                        android.graphics.Path().apply {
                            addRoundRect(l, t, r, b2, r2, r2, android.graphics.Path.Direction.CW)
                            canvas.save(); canvas.clipPath(this)
                            if (zm > 1.0001f) {
                                val sw = (pipTargetW / zm).toInt(); val sh = (pipTargetH / zm).toInt()
                                val sl = pipBmp.width / 2 - sw / 2; val st = pipBmp.height / 2 - sh / 2
                                canvas.drawBitmap(pipBmp, Rect(sl, st, sl + sw, st + sh),
                                    Rect(px, py, px + pipTargetW, py + pipTargetH), null)
                            } else {
                                canvas.drawBitmap(pipBmp, l, t, null)
                            }
                            canvas.restore()
                        }
                    }
                }
                // Photo overlays (multi-photo) with rounded rect + shadow + zoom
                for (po in photoOverlays) {
                    val pBmp = po.bitmap
                    val ppx = (po.normX * OUT_W).toInt().coerceIn(0, OUT_W)
                    val ppy = (po.normY * OUT_H).toInt().coerceIn(0, OUT_H)
                    val ppw = (po.normW * OUT_W).toInt().coerceIn(8, OUT_W - ppx)
                    val pph = (po.normH * OUT_H).toInt().coerceIn(8, OUT_H - ppy)
                    if (ppw > 0 && pph > 0) {
                        val l = ppx.toFloat(); val t = ppy.toFloat()
                        val r = (ppx + ppw).toFloat(); val b2 = (ppy + pph).toFloat()
                        val r2 = pipCornerRadius.coerceIn(0f, 30f)
                        val sa = pipShadowAlpha.coerceIn(0, 255)
                        val zm = pipZoom.coerceAtLeast(1f)

                        val sp = pipShadowPaint!!
                        sp.color = Color.argb(sa, 0, 0, 0)
                        canvas.drawRoundRect(l + PIP_SHADOW_DX, t + PIP_SHADOW_DY,
                            r + PIP_SHADOW_DX, b2 + PIP_SHADOW_DY, r2, r2, sp)

                        android.graphics.Path().apply {
                            addRoundRect(l, t, r, b2, r2, r2, android.graphics.Path.Direction.CW)
                            canvas.save(); canvas.clipPath(this)
                            val srcW = pBmp.width; val srcH = pBmp.height
                            val scale = maxOf(ppw.toFloat() / srcW, pph.toFloat() / srcH)
                            val sw = (ppw / scale).toInt().coerceAtMost(srcW)
                            val sh = (pph / scale).toInt().coerceAtMost(srcH)
                            val sl = (srcW - sw) / 2; val st = (srcH - sh) / 2
                            if (zm > 1.0001f) {
                                val zsw = (sw / zm).toInt().coerceAtMost(sw)
                                val zsh = (sh / zm).toInt().coerceAtMost(sh)
                                val zsl = sl + (sw - zsw) / 2; val zst = st + (sh - zsh) / 2
                                canvas.drawBitmap(pBmp,
                                    Rect(zsl, zst, zsl + zsw, zst + zsh),
                                    Rect(ppx, ppy, ppx + ppw, ppy + pph), null)
                            } else {
                                canvas.drawBitmap(pBmp,
                                    Rect(sl, st, sl + sw, st + sh),
                                    Rect(ppx, ppy, ppx + ppw, ppy + pph), null)
                            }
                            canvas.restore()
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e("Mixer", "renderToEncoderSurface failed", e)
            } finally {
                if (canvas != null) {
                    try { surface.unlockCanvasAndPost(canvas) } catch (_: Exception) {}
                }
            }
            compositeFrameCount++
            if (compositeFrameCount % 30 == 1) {
                Log.d("Mixer", "compositeFrame=$compositeFrameCount, pip=$pipEnabled, photos=${photoOverlays.size}, photoPos=${photoOverlays.map { "(x=${(it.normX*OUT_W).toInt()},y=${(it.normY*OUT_H).toInt()},w=${(it.normW*OUT_W).toInt()},h=${(it.normH*OUT_H).toInt()})" }}")
            }
        }

        // Preview (Texture widget)
        if (bmp != null && previewSurface?.isValid == true) {
            var pCanvas: Canvas? = null
            try {
                pCanvas = previewSurface!!.lockCanvas(null)
                if (pCanvas != null) {
                    pCanvas.drawBitmap(bmp, null, Rect(0, 0, PREVIEW_TEX_W, PREVIEW_TEX_H), null)
                }
            } catch (_: Exception) {
            } finally {
                if (pCanvas != null) {
                    try { previewSurface!!.unlockCanvasAndPost(pCanvas) } catch (_: Exception) {}
                }
            }
        }

        // PiP EventChannel preview (throttled)
        val mainHandler = Handler(Looper.getMainLooper())
        if (pipEnabled && pipRgba != null && pipPreviewSink != null && pipTargetW > 0 && pipTargetH > 0) {
            pipPreviewFrameCount++
            if (pipPreviewFrameCount % 3 == 0) {
                val scale = minOf(PREVIEW_W.toFloat() / pipTargetW, PREVIEW_H.toFloat() / pipTargetH).coerceIn(0f, 1f)
                val pw = (pipTargetW * scale).toInt().coerceAtLeast(1)
                val ph = (pipTargetH * scale).toInt().coerceAtLeast(1)
                val buf = ByteArray(pw * ph * 4)
                downscaleRgbaInto(pipRgba, pipTargetW, pipTargetH, pw, ph, buf)
                val map = HashMap<String, Any?>()
                map["width"] = pw; map["height"] = ph; map["pixels"] = buf
                mainHandler.post { pipPreviewSink?.success(map) }
            }
        }
    }

    // ── GPU camera open (uses Surface from GpuRenderer) ──

    private fun openMixerCameraGpu(
        mgr: CameraManager, camId: String, isMain: Boolean,
        targetSurface: Surface
    ) {
        val chars = mgr.getCameraCharacteristics(camId)
        val sensorRot = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        if (isMain) mainCameraRotation = sensorRot else pipCameraRotation = sensorRot

        mgr.openCamera(camId, object : CameraDevice.StateCallback() {
            override fun onOpened(c: CameraDevice) {
                if (isMain) mainCameraDevice = c else recPipCameraDevice = c
                val req = c.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply { addTarget(targetSurface) }
                c.createCaptureSession(listOf(targetSurface), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        if (isMain) mainCaptureSession = s else recPipCaptureSession = s
                        s.setRepeatingRequest(req.build(), null, recBgHandler)
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) {}
                }, recBgHandler)
            }
            override fun onDisconnected(c: CameraDevice) { c.close() }
            override fun onError(c: CameraDevice, e: Int) { c.close() }
        }, recBgHandler)
    }

    private fun renderToSurface(surface: Surface?, bitmap: Bitmap?) {
        if (surface == null || bitmap == null || !surface.isValid) return
        try {
            val canvas = surface.lockCanvas(null)
            if (canvas != null) {
                canvas.drawBitmap(bitmap, 0f, 0f, null)
                surface.unlockCanvasAndPost(canvas)
            }
        } catch (e: Exception) {
            Log.e("Mixer", "renderToSurface failed", e)
        }
    }

    private fun downscaleRgbaInto(src: ByteArray, srcW: Int, srcH: Int, dstW: Int, dstH: Int, dst: ByteArray) {
        for (py in 0 until dstH) {
            for (px in 0 until dstW) {
                val sx = (px * srcW) / dstW
                val sy = (py * srcH) / dstH
                val si = (sy * srcW + sx) * 4
                val di = (py * dstW + px) * 4
                dst[di] = src[si]; dst[di + 1] = src[si + 1]
                dst[di + 2] = src[si + 2]; dst[di + 3] = src[si + 3]
            }
        }
    }

    // ══════════════════════════════════════════════
    //  Notifications
    // ══════════════════════════════════════════════

    private fun ensureSaveChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(SAVE_CHANNEL_ID, "Video Save", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows save progress for recorded videos"
            }
            saveNotifManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            saveNotifManager?.createNotificationChannel(ch)
        }
    }

    private fun showSavingNotification() {
        ensureSaveChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) return
        }
        val notif = NotificationCompat.Builder(this, SAVE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_save)
            .setContentTitle("Saving video")
            .setContentText("Processing your recording…")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setProgress(0, 0, true)
            .build()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(SAVE_NOTIFICATION_ID, notif)
    }

    private fun dismissSavingNotification() {
        try {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(SAVE_NOTIFICATION_ID)
        } catch (_: Exception) {}
    }

    // ══════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════

    private fun findCameraId(mgr: CameraManager, facing: Int): String? {
        return mgr.cameraIdList.firstOrNull { id ->
            mgr.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == facing
        }
    }

    private fun findFirstBackFacing(mgr: CameraManager): String? = findCameraId(mgr, CameraCharacteristics.LENS_FACING_BACK)
    private fun findFirstFrontFacing(mgr: CameraManager): String? = findCameraId(mgr, CameraCharacteristics.LENS_FACING_FRONT)

    private fun objSessionCb(
        onOk: (CameraCaptureSession) -> Unit,
        onFail: (CameraCaptureSession) -> Unit
    ) = object : CameraCaptureSession.StateCallback() {
        override fun onConfigured(s: CameraCaptureSession) { onOk(s) }
        override fun onConfigureFailed(s: CameraCaptureSession) { onFail(s) }
    }

    override fun onDestroy() {
        isRecording = false
        stopPipPreview()
        try {
            mainCaptureSession?.close(); mainCaptureSession = null
            mainCameraDevice?.close(); mainCameraDevice = null
            mainImageReader?.close(); mainImageReader = null
            recPipCaptureSession?.close(); recPipCaptureSession = null
            recPipCameraDevice?.close(); recPipCameraDevice = null
            recPipImageReader?.close(); recPipImageReader = null
            recBgThread?.quitSafely()
            try { audioRecord?.stop(); audioRecord?.release(); audioRecord = null } catch (_: Exception) {}
            audioCaptureThread?.quitSafely(); audioCaptureThread = null; audioCaptureHandler = null
            try { audioEncoder?.stop(); audioEncoder?.release(); audioEncoder = null } catch (_: Exception) {}
            compositeBitmap?.recycle(); compositeBitmap = null
            pipBitmap?.recycle(); pipBitmap = null
            for (po in photoOverlays) { po.bitmap.recycle() }
            photoOverlays.clear()
            previewSurface = null
            previewTextureEntry?.release(); previewTextureEntry = null
            compositeThread?.quitSafely(); compositeThread = null; compositeHandler = null
            try { mediaCodec?.signalEndOfInputStream() } catch (_: Exception) {}
            try { encoderThread?.join(3000) } catch (_: Exception) {}
            if (!isEncoderDone) {
                try { mediaCodec?.stop(); mediaCodec?.release(); mediaCodec = null; mediaMuxer?.stop(); mediaMuxer?.release(); mediaMuxer = null } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
