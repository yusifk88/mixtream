#include <jni.h>
#include <stdint.h>

#define CLAMP(x, lo, hi) ((x) < (lo) ? (lo) : ((x) > (hi) ? (hi) : (x)))

JNIEXPORT void JNICALL
Java_com_mixtream_app_YuvConverter_yuvToRgbaNative(
    JNIEnv *env, jobject thiz,
    jbyteArray y_arr, jint y_stride, jint y_len,
    jbyteArray u_arr, jint u_stride, jint u_len,
    jbyteArray v_arr, jint v_stride, jint v_len,
    jint uv_pixel_stride,
    jint img_w, jint img_h,
    jint out_w, jint out_h,
    jint rotation, jboolean mirror,
    jbyteArray out_arr)
{
    jbyte *y = (*env)->GetByteArrayElements(env, y_arr, NULL);
    jbyte *u = (*env)->GetByteArrayElements(env, u_arr, NULL);
    jbyte *v = (*env)->GetByteArrayElements(env, v_arr, NULL);
    jbyte *out = (*env)->GetByteArrayElements(env, out_arr, NULL);

    if (!y || !u || !v || !out) {
        if (y) (*env)->ReleaseByteArrayElements(env, y_arr, y, JNI_ABORT);
        if (u) (*env)->ReleaseByteArrayElements(env, u_arr, u, JNI_ABORT);
        if (v) (*env)->ReleaseByteArrayElements(env, v_arr, v, JNI_ABORT);
        if (out) (*env)->ReleaseByteArrayElements(env, out_arr, out, JNI_ABORT);
        return;
    }

    int is_interleaved = (uv_pixel_stride == 2);

    // Compute center-crop rect in source to match output aspect ratio
    int crop_x = 0, crop_y = 0, crop_w = img_w, crop_h = img_h;
    {
        float out_aspect = (float)out_w / out_h;
        if (rotation == 90 || rotation == 270) {
            // After rotation, width maps from source height, height from source width
            float src_aspect = (float)img_h / img_w;
            if (src_aspect > out_aspect) {
                // Source after rotation is wider → crop source height
                crop_h = (int)(img_w * out_aspect + 0.5f);
                crop_y = (img_h - crop_h) / 2;
            } else {
                // Source after rotation is taller → crop source width
                crop_w = (int)(img_h / out_aspect + 0.5f);
                crop_x = (img_w - crop_w) / 2;
            }
        } else {
            float src_aspect = (float)img_w / img_h;
            if (src_aspect > out_aspect) {
                // Source is wider than output → crop width
                crop_w = (int)(img_h * out_aspect + 0.5f);
                crop_x = (img_w - crop_w) / 2;
            } else {
                // Source is taller than output → crop height
                crop_h = (int)(img_w / out_aspect + 0.5f);
                crop_y = (img_h - crop_h) / 2;
            }
        }
    }

    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int dx = mirror ? out_w - 1 - ox : ox;
            int dy = oy;

            int sx, sy;
            switch (rotation) {
                case 90:
                    sx = crop_x + dy * crop_w / out_h;
                    sy = crop_y + (out_w - 1 - dx) * crop_h / out_w;
                    break;
                case 180:
                    sx = crop_x + (out_w - 1 - dx) * crop_w / out_w;
                    sy = crop_y + (out_h - 1 - dy) * crop_h / out_h;
                    break;
                case 270:
                    sx = crop_x + (out_h - 1 - dy) * crop_w / out_h;
                    sy = crop_y + dx * crop_h / out_w;
                    break;
                default:
                    sx = crop_x + dx * crop_w / out_w;
                    sy = crop_y + dy * crop_h / out_h;
                    break;
            }

            if (sx < 0) sx = 0;
            if (sx >= img_w) sx = img_w - 1;
            if (sy < 0) sy = 0;
            if (sy >= img_h) sy = img_h - 1;

            int y_idx = sy * y_stride + sx;
            int uv_y = sy >> 1;
            int uv_x = sx >> 1;

            int yv = (y_idx >= 0 && y_idx < y_len) ? ((uint8_t *)y)[y_idx] : 0;
            int u_val = 128;
            int v_val = 128;

            if (is_interleaved) {
                int uv_base = uv_y * u_stride + uv_x * 2;
                if (uv_base >= 0 && uv_base + 1 < u_len) {
                    u_val = ((uint8_t *)u)[uv_base];
                    v_val = ((uint8_t *)u)[uv_base + 1];
                }
            } else {
                int uv_base = uv_y * u_stride + uv_x;
                if (uv_base >= 0 && uv_base < u_len) {
                    u_val = ((uint8_t *)u)[uv_base];
                }
                int v_idx = uv_y * v_stride + uv_x;
                if (v_idx >= 0 && v_idx < v_len) {
                    v_val = ((uint8_t *)v)[v_idx];
                }
            }

            int r = CLAMP(yv + ((1436 * (v_val - 128)) >> 10), 0, 255);
            int g = CLAMP(yv - ((352 * (u_val - 128)) >> 10) - ((731 * (v_val - 128)) >> 10), 0, 255);
            int b = CLAMP(yv + ((1815 * (u_val - 128)) >> 10), 0, 255);

            int i = (oy * out_w + ox) * 4;
            out[i]     = (jbyte)r;
            out[i + 1] = (jbyte)g;
            out[i + 2] = (jbyte)b;
            out[i + 3] = (jbyte)255;
        }
    }

    (*env)->ReleaseByteArrayElements(env, y_arr, y, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, u_arr, u, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, v_arr, v, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, out_arr, out, 0);
}
