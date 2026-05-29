package com.mixtream.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import java.io.File

class SaveVideoService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val path = intent?.getStringExtra(EXTRA_PATH) ?: run { stopSelf(); return START_NOT_STICKY }
        val file = File(path)
        if (!file.exists() || file.length() < 4096) { file.delete(); stopSelf(); return START_NOT_STICKY }

        ensureChannel()
        startForeground(NOTIF_ID, buildNotif("Saving video…", true))

        Thread {
            try {
                copyToGallery(file)
                updateNotif("Video saved", false)
                Thread.sleep(2000)
            } catch (e: Exception) {
                updateNotif("Save failed", false)
                e.printStackTrace()
            } finally {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }.start()

        return START_NOT_STICKY
    }

    private fun copyToGallery(file: File) {
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
                file.delete()
            } catch (e: Exception) {
                try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            }
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL_ID, "Video Save", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Saving recorded videos"
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
        }
    }

    private fun buildNotif(text: String, indeterminate: Boolean): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_save)
            .setContentTitle("MixStream")
            .setContentText(text)
            .setOngoing(indeterminate)
            .setProgress(0, 0, indeterminate)
            .build()
    }

    private fun updateNotif(text: String, indeterminate: Boolean) {
        val mgr = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(NOTIF_ID, buildNotif(text, indeterminate))
    }

    companion object {
        private const val CHANNEL_ID = "mixstream_video_save"
        private const val NOTIF_ID = 1001
        private const val EXTRA_PATH = "file_path"
    }
}
