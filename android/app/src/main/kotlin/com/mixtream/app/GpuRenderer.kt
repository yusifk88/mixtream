package com.mixtream.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class GpuRenderer {

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var program = 0
    private var vsTextureMatrixLoc = 0
    private var fsPipPosLoc = 0
    private var fsPipSizeLoc = 0
    private var fsCornerRadiusLoc = 0
    private var fsShadowAlphaLoc = 0
    private var fsOutputSizeLoc = 0
    private var fsZoomLoc = 0

    private var vbo = 0
    private val quadVertices: FloatBuffer

    var mainSurfaceTexture: SurfaceTexture? = null
        private set
    var pipSurfaceTexture: SurfaceTexture? = null
        private set
    var mainInputSurface: Surface? = null
        private set
    var pipInputSurface: Surface? = null
        private set

    private var outW = 1080
    private var outH = 1920
    private var pipNormX = 0.82f
    private var pipNormY = 0.11f
    private var pipNormW = 0.17f
    private var pipNormH = 0.22f
    private var pipCornerRadiusPx = 14f
    private var pipShadowAlpha = 70
    private var pipZoom = 1.0f
    private var pipEnabled = true

    private var mainTexId = 0
    private var pipTexId = 0
    private val mainTexMatrix = FloatArray(16)
    private val pipTexMatrix = FloatArray(16)
    private var firstRender = true

    // Preview via CPU readback + Canvas draw (avoids EGL surface switching)
    private var previewOutput: Surface? = null
    private var previewW = 540
    private var previewH = 960
    private var previewBitmap: Bitmap? = null
    private var previewReadCount = 0
    private var previewTargetRect: Rect? = null

    private val EGL_CONTEXT_CLIENT_VERSION = 0x3098

    companion object {
        private const val TAG = "GpuRenderer"

        private val VERTEX_SHADER = """
            #version 100
            attribute vec4 aPosition;
            attribute vec2 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord;
            }
        """.trimIndent()

        private val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uMainTex;
            uniform samplerExternalOES uPipTex;
            uniform mat4 uMainTexMatrix;
            uniform mat4 uPipTexMatrix;
            uniform vec2 uPipPos;
            uniform vec2 uPipSize;
            uniform float uCornerRadius;
            uniform float uShadowAlpha;
            uniform vec2 uOutputSize;
            uniform float uZoom;
            varying vec2 vTextureCoord;
            void main() {
                vec4 mainColor = texture2D(uMainTex, (uMainTexMatrix * vec4(vTextureCoord, 0.0, 1.0)).xy);
                vec2 pipNdc = (vTextureCoord - uPipPos) / uPipSize;
                if (pipNdc.x >= 0.0 && pipNdc.x <= 1.0 && pipNdc.y >= 0.0 && pipNdc.y <= 1.0) {
                    vec2 zoomed = (pipNdc - 0.5) / uZoom + 0.5;
                    vec4 pipColor = texture2D(uPipTex, (uPipTexMatrix * vec4(zoomed, 0.0, 1.0)).xy);
                    vec2 pipPx = pipNdc * uOutputSize * uPipSize;
                    vec2 cornerDist = min(pipPx, uOutputSize * uPipSize - pipPx);
                    float edgeDist = min(cornerDist.x, cornerDist.y);
                    float radius = uCornerRadius;
                    float alpha = 1.0 - smoothstep(radius - 0.5, radius + 0.5, edgeDist);
                    float shadow = uShadowAlpha / 255.0 * (1.0 - smoothstep(radius - 2.0, radius + 8.0, edgeDist));
                    vec4 shadowColor = vec4(0.0, 0.0, 0.0, shadow * 0.3);
                    pipColor.a *= alpha;
                    mainColor = mix(mainColor, shadowColor, shadowColor.a);
                    mainColor = mix(mainColor, pipColor, pipColor.a);
                }
                gl_FragColor = mainColor;
            }
        """.trimIndent()
    }

    init {
        val v = floatArrayOf(
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f
        )
        quadVertices = ByteBuffer.allocateDirect(v.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(v)
        quadVertices.position(0)
    }

    fun setPreviewTarget(surface: Surface?, width: Int, height: Int) {
        previewOutput = surface
        previewW = width
        previewH = height
        previewBitmap?.recycle()
        previewBitmap = null
        if (surface != null) {
            try {
                previewBitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                previewTargetRect = Rect(0, 0, width, height)
            } catch (e: Exception) {
                Log.e(TAG, "preview bitmap creation failed", e)
                previewOutput = null
            }
        }
    }

    fun setup(encoderSurface: Surface, width: Int, height: Int) {
        outW = width; outH = height

        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            Log.e(TAG, "eglGetDisplay failed")
            return
        }
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            Log.e(TAG, "eglInitialize failed")
            return
        }
        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)) {
            Log.e(TAG, "eglChooseConfig failed")
            return
        }
        val ctxAttribs = intArrayOf(EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "eglCreateContext failed")
            return
        }
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], encoderSurface, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            Log.e(TAG, "eglCreateWindowSurface failed")
            return
        }
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            Log.e(TAG, "eglMakeCurrent failed")
            return
        }

        program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        if (program == 0) {
            Log.e(TAG, "shader program creation failed")
            return
        }
        GLES20.glUseProgram(program)

        vsTextureMatrixLoc = GLES20.glGetUniformLocation(program, "uMainTexMatrix")
        val pipTexMatrixLoc = GLES20.glGetUniformLocation(program, "uPipTexMatrix")
        fsPipPosLoc = GLES20.glGetUniformLocation(program, "uPipPos")
        fsPipSizeLoc = GLES20.glGetUniformLocation(program, "uPipSize")
        fsCornerRadiusLoc = GLES20.glGetUniformLocation(program, "uCornerRadius")
        fsShadowAlphaLoc = GLES20.glGetUniformLocation(program, "uShadowAlpha")
        fsOutputSizeLoc = GLES20.glGetUniformLocation(program, "uOutputSize")
        fsZoomLoc = GLES20.glGetUniformLocation(program, "uZoom")

        mainTexId = createExternalTexture()
        pipTexId = createExternalTexture()

        mainSurfaceTexture = SurfaceTexture(mainTexId)
        pipSurfaceTexture = SurfaceTexture(pipTexId)
        mainInputSurface = Surface(mainSurfaceTexture!!)
        pipInputSurface = Surface(pipSurfaceTexture!!)

        val posLoc = GLES20.glGetAttribLocation(program, "aPosition")
        val texLoc = GLES20.glGetAttribLocation(program, "aTextureCoord")
        val vboArr = IntArray(1)
        GLES20.glGenBuffers(1, vboArr, 0)
        vbo = vboArr[0]
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, quadVertices.capacity() * 4, quadVertices, GLES20.GL_STATIC_DRAW)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glVertexAttribPointer(posLoc, 2, GLES20.GL_FLOAT, false, 16, 0)
        GLES20.glEnableVertexAttribArray(texLoc)
        GLES20.glVertexAttribPointer(texLoc, 2, GLES20.GL_FLOAT, false, 16, 8)

        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uMainTex"), 0)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uPipTex"), 1)
        GLES20.glUniformMatrix4fv(pipTexMatrixLoc, 1, false, FloatArray(16), 0)

        firstRender = true
        Log.d(TAG, "GPU renderer initialized ${width}x${height}")
    }

    fun setPipConfig(
        normX: Float, normY: Float, normW: Float, normH: Float,
        cornerRadius: Float, shadowAlpha: Int, zoom: Float, enabled: Boolean
    ) {
        pipNormX = normX; pipNormY = normY
        pipNormW = normW; pipNormH = normH
        pipCornerRadiusPx = cornerRadius
        pipShadowAlpha = shadowAlpha
        pipZoom = zoom.coerceAtLeast(1f)
        pipEnabled = enabled
    }

    fun render(): Long {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || program == 0) return -1L

        mainSurfaceTexture?.updateTexImage()
        mainSurfaceTexture?.getTransformMatrix(mainTexMatrix)

        if (pipEnabled) {
            pipSurfaceTexture?.updateTexImage()
            pipSurfaceTexture?.getTransformMatrix(pipTexMatrix)
        }

        // Render to encoder surface
        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        drawScene()

        // Preview readback — throttled, uses glReadPixels + Canvas blit to Flutter Texture Surface
        val previewSurf = previewOutput
        if (previewSurf != null && previewSurf.isValid && previewBitmap != null) {
            previewReadCount++
            if (previewReadCount % 2 == 0) {
                val pw = previewW; val ph = previewH
                val buf = ByteBuffer.allocateDirect(pw * ph * 4)
                GLES20.glReadPixels(0, (outH - ph) / 2, pw, ph, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
                buf.position(0)
                previewBitmap!!.copyPixelsFromBuffer(buf)
                try {
                    val canvas = previewSurf.lockCanvas(null)
                    if (canvas != null) {
                        canvas.drawBitmap(previewBitmap!!, null, previewTargetRect!!, null)
                        previewSurf.unlockCanvasAndPost(canvas)
                    }
                } catch (_: Exception) {}
            }
        }

        val ptsNs = System.nanoTime()
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)

        if (firstRender) {
            firstRender = false
            Log.d(TAG, "first frame rendered, PTS=$ptsNs")
        }
        return ptsNs
    }

    private fun drawScene() {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, mainTexId)
        GLES20.glUniformMatrix4fv(vsTextureMatrixLoc, 1, false, mainTexMatrix, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, pipTexId)
        val pipTexMatLoc = GLES20.glGetUniformLocation(program, "uPipTexMatrix")
        GLES20.glUniformMatrix4fv(pipTexMatLoc, 1, false, pipTexMatrix, 0)

        GLES20.glUniform2f(fsPipPosLoc, pipNormX, pipNormY)
        GLES20.glUniform2f(fsPipSizeLoc, pipNormW, pipNormH)
        GLES20.glUniform1f(fsCornerRadiusLoc, pipCornerRadiusPx.coerceIn(0f, 30f))
        GLES20.glUniform1f(fsShadowAlphaLoc, pipShadowAlpha.coerceIn(0, 255).toFloat())
        GLES20.glUniform2f(fsOutputSizeLoc, outW.toFloat(), outH.toFloat())
        GLES20.glUniform1f(fsZoomLoc, pipZoom)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    fun destroy() {
        previewOutput = null
        previewBitmap?.recycle(); previewBitmap = null
        previewTargetRect = null
        GLES20.glDeleteProgram(program)
        if (vbo != 0) {
            GLES20.glDeleteBuffers(1, intArrayOf(vbo), 0)
        }
        if (mainTexId != 0) GLES20.glDeleteTextures(1, intArrayOf(mainTexId), 0)
        if (pipTexId != 0) GLES20.glDeleteTextures(1, intArrayOf(pipTexId), 0)
        mainSurfaceTexture?.release(); mainSurfaceTexture = null
        pipSurfaceTexture?.release(); pipSurfaceTexture = null
        mainInputSurface?.release(); mainInputSurface = null
        pipInputSurface?.release(); pipInputSurface = null
        if (eglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
            eglSurface = EGL14.EGL_NO_SURFACE
        }
        if (eglContext != EGL14.EGL_NO_CONTEXT) {
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            eglContext = EGL14.EGL_NO_CONTEXT
        }
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglTerminate(eglDisplay)
            eglDisplay = EGL14.EGL_NO_DISPLAY
        }
        firstRender = true
        Log.d(TAG, "GPU renderer destroyed")
    }

    private fun createExternalTexture(): Int {
        val texArr = IntArray(1)
        GLES20.glGenTextures(1, texArr, 0)
        val texId = texArr[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return texId
    }

    private fun loadShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            Log.e(TAG, "shader compile error: ${GLES20.glGetShaderInfoLog(shader)}")
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun createProgram(vertexSrc: String, fragmentSrc: String): Int {
        val vs = loadShader(GLES20.GL_VERTEX_SHADER, vertexSrc)
        val fs = loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentSrc)
        if (vs == 0 || fs == 0) return 0
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linked, 0)
        if (linked[0] == 0) {
            Log.e(TAG, "program link error: ${GLES20.glGetProgramInfoLog(prog)}")
            GLES20.glDeleteProgram(prog)
            return 0
        }
        return prog
    }
}
