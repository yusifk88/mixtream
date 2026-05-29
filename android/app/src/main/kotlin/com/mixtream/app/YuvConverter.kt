package com.mixtream.app

import android.media.Image

object YuvConverter {

    private var nativeLoaded = false

    init {
        try {
            System.loadLibrary("yuv_converter")
            nativeLoaded = true
        } catch (_: UnsatisfiedLinkError) {
            nativeLoaded = false
        }
    }

    fun yuvToRgba(
        image: Image, outW: Int, outH: Int, rotation: Int, mirror: Boolean,
        reuseOut: ByteArray? = null
    ): ByteArray {
        val planes = image.planes
        val imgW = image.width; val imgH = image.height

        val yBuf = planes[0].buffer; val uBuf = planes[1].buffer; val vBuf = planes[2].buffer
        val yBytes = ByteArray(yBuf.remaining()).apply { yBuf.get(this) }
        val uBytes = ByteArray(uBuf.remaining()).apply { uBuf.get(this) }
        val vBytes = ByteArray(vBuf.remaining()).apply { vBuf.get(this) }

        val rgba = reuseOut?.takeIf { it.size == outW * outH * 4 } ?: ByteArray(outW * outH * 4)

        if (nativeLoaded) {
            yuvToRgbaNative(
                yBytes, planes[0].rowStride, yBytes.size,
                uBytes, planes[1].rowStride, uBytes.size,
                vBytes, planes[2].rowStride, vBytes.size,
                planes[1].pixelStride,
                imgW, imgH,
                outW, outH,
                rotation, mirror,
                rgba
            )
        } else {
            yuvToRgbaFallback(
                yBytes, planes[0].rowStride,
                uBytes, planes[1].rowStride,
                vBytes, planes[2].rowStride,
                planes[1].pixelStride,
                imgW, imgH, outW, outH, rotation, mirror, rgba
            )
        }
        return rgba
    }

    private fun yuvToRgbaFallback(
        yBytes: ByteArray, yStride: Int,
        uBytes: ByteArray, uStride: Int,
        vBytes: ByteArray, vStride: Int,
        uvPixStride: Int,
        imgW: Int, imgH: Int,
        outW: Int, outH: Int,
        rotation: Int, mirror: Boolean,
        rgba: ByteArray
    ) {
        val yLen = yBytes.size; val uLen = uBytes.size; val vLen = vBytes.size
        val isInterleaved = uvPixStride == 2

        // Center-crop source to match output aspect ratio
        val outAspect = outW.toFloat() / outH
        val cropX: Int; val cropY: Int; val cropW: Int; val cropH: Int
        if (rotation == 90 || rotation == 270) {
            val srcAspect = imgH.toFloat() / imgW
            if (srcAspect > outAspect) {
                cropW = imgW
                cropH = (imgW.toFloat() * outAspect + 0.5f).toInt()
                cropX = 0
                cropY = (imgH - cropH) / 2
            } else {
                cropH = imgH
                cropW = (imgH.toFloat() / outAspect + 0.5f).toInt()
                cropX = (imgW - cropW) / 2
                cropY = 0
            }
        } else {
            val srcAspect = imgW.toFloat() / imgH
            if (srcAspect > outAspect) {
                cropW = (imgH.toFloat() * outAspect + 0.5f).toInt()
                cropH = imgH
                cropX = (imgW - cropW) / 2
                cropY = 0
            } else {
                cropW = imgW
                cropH = (imgW.toFloat() / outAspect + 0.5f).toInt()
                cropX = 0
                cropY = (imgH - cropH) / 2
            }
        }

        for (oy in 0 until outH) {
            for (ox in 0 until outW) {
                val dispX = if (mirror) outW - 1 - ox else ox
                val dispY = oy
                val (sx, sy) = when (rotation) {
                    90 -> Pair(cropX + dispY * cropW / outH, cropY + (outW - 1 - dispX) * cropH / outW)
                    180 -> Pair(cropX + (outW - 1 - dispX) * cropW / outW, cropY + (outH - 1 - dispY) * cropH / outH)
                    270 -> Pair(cropX + (outH - 1 - dispY) * cropW / outH, cropY + dispX * cropH / outW)
                    else -> Pair(cropX + dispX * cropW / outW, cropY + dispY * cropH / outH)
                }

                val yIdx = sy * yStride + sx
                val uvY = sy shr 1; val uvX = sx shr 1
                val uvBase = uvY * uStride + uvX * uvPixStride

                val yv = if (yIdx in 0 until yLen) yBytes[yIdx].toInt() and 0xff else 0
                var u = 128; var v = 128
                if (isInterleaved) {
                    u = if (uvBase in 0 until uLen) uBytes[uvBase].toInt() and 0xff else 128
                    v = if (uvBase + 1 in 0 until uLen) uBytes[uvBase + 1].toInt() and 0xff else 128
                } else {
                    u = if (uvBase in 0 until uLen) uBytes[uvBase].toInt() and 0xff else 128
                    val vIdx = uvY * vStride + uvX
                    v = if (vIdx in 0 until vLen) vBytes[vIdx].toInt() and 0xff else 128
                }

                val r = yv + ((1436 * (v - 128)) shr 10)
                val g = yv - ((352 * (u - 128)) shr 10) - ((731 * (v - 128)) shr 10)
                val b = yv + ((1815 * (u - 128)) shr 10)

                val i = (oy * outW + ox) * 4
                rgba[i] = r.coerceIn(0, 255).toByte()
                rgba[i + 1] = g.coerceIn(0, 255).toByte()
                rgba[i + 2] = b.coerceIn(0, 255).toByte()
                rgba[i + 3] = 255.toByte()
            }
        }
    }

    private external fun yuvToRgbaNative(
        yArr: ByteArray, yStride: Int, yLen: Int,
        uArr: ByteArray, uStride: Int, uLen: Int,
        vArr: ByteArray, vStride: Int, vLen: Int,
        uvPixelStride: Int,
        imgW: Int, imgH: Int,
        outW: Int, outH: Int,
        rotation: Int, mirror: Boolean,
        outArr: ByteArray
    )
}
