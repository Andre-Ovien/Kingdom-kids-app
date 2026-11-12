package com.andreovien.kingdomkids

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private var motionChannel: EventChannel? = null
    private var motionHandler: SailingMotionHandler? = null
    private var foreground = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        motionHandler?.dispose()
        motionChannel?.setStreamHandler(null)
        val handler = SailingMotionHandler(this)
        handler.setForeground(foreground)
        motionHandler = handler
        motionChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "kingdom_kids/sailing_motion")
            .also { it.setStreamHandler(handler) }
    }

    override fun onResume() {
        super.onResume()
        foreground = true
        motionHandler?.setForeground(true)
    }

    override fun onPause() {
        foreground = false
        motionHandler?.setForeground(false)
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        motionHandler?.dispose()
        motionChannel?.setStreamHandler(null)
        motionHandler = null
        motionChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        motionHandler?.dispose()
        super.onDestroy()
    }
}

private class SailingMotionHandler(private val activity: MainActivity) :
    EventChannel.StreamHandler, SensorEventListener {
    private val manager = activity.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val accelerometer = manager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private var events: EventChannel.EventSink? = null
    private var foreground = false
    private var registered = false
    private var lastSample = 0L
    private var lastEmission = 0L
    private val gravity = FloatArray(3)

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        stop()
        events = sink
        if (manager == null || accelerometer == null) {
            fail("Device tilt is unavailable.")
            return
        }
        start()
    }

    override fun onCancel(arguments: Any?) {
        events = null
        stop()
    }

    fun setForeground(active: Boolean) {
        foreground = active
        if (active) start() else stop()
    }

    private fun start() {
        if (!foreground || events == null || registered) return
        try {
            registered = manager?.registerListener(this, accelerometer, 33_333) == true
            if (!registered) fail("Device tilt could not start.")
        } catch (_: SecurityException) {
            fail("Device tilt is unavailable.")
        }
    }

    private fun stop() {
        manager?.unregisterListener(this)
        registered = false
        lastSample = 0L
        lastEmission = 0L
        gravity.fill(0f)
    }

    private fun fail(message: String) {
        events?.error("motion_unavailable", message, null)
        events?.endOfStream()
        events = null
        stop()
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (!foreground || !registered || events == null || event.values.size < 3) return
        if ((0..2).any { !event.values[it].isFinite() }) return
        if (lastSample == 0L) {
            for (axis in 0..2) gravity[axis] = event.values[axis]
        } else {
            val seconds = ((event.timestamp - lastSample) / 1_000_000_000.0).coerceIn(0.001, 0.25)
            val alpha = (0.12 / (0.12 + seconds)).toFloat()
            for (axis in 0..2) gravity[axis] = alpha * gravity[axis] + (1f - alpha) * event.values[axis]
        }
        lastSample = event.timestamp
        if (lastEmission != 0L && event.timestamp - lastEmission < 30_000_000L) return
        lastEmission = event.timestamp
        @Suppress("DEPRECATION")
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: Surface.ROTATION_0
        } else {
            activity.windowManager.defaultDisplay.rotation
        }
        // Sensor axes use the device's natural orientation, including on
        // tablets. Rotate into the actual screen before converting to tilt.
        val screenX = when (rotation) {
            Surface.ROTATION_90 -> gravity[1]
            Surface.ROTATION_180 -> -gravity[0]
            Surface.ROTATION_270 -> -gravity[1]
            else -> gravity[0]
        }
        // Android reports supporting acceleration, opposite to Core Motion's
        // gravity direction. Both platforms expose right-positive here.
        events?.success((-screenX / SensorManager.GRAVITY_EARTH).toDouble().coerceIn(-1.0, 1.0))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    fun dispose() {
        events = null
        stop()
    }
}
