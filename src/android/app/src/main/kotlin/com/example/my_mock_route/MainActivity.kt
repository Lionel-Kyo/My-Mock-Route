package com.example.my_mock_route

import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.StepsRecord

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.my_mock_route/gps"
    private lateinit var locationManager: LocationManager

    private val healthPermissions = setOf(HealthPermission.getWritePermission(StepsRecord::class))

    companion object {
        private var channel: MethodChannel? = null

        fun sendStartFailedToFlutter(errorMsg: String) {
            Handler(Looper.getMainLooper()).post {
                channel?.invokeMethod("onStartFailed", errorMsg)
            }
        }

        fun sendLocationToFlutter(lat: Double, lng: Double) {
            val args = mapOf("lat" to lat, "lng" to lng)
            Handler(Looper.getMainLooper()).post {
                channel?.invokeMethod("onLocationUpdate", args)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.my_mock_route/gps_stream")
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startNativeService" -> {
                    val rawList = call.argument<List<Any?>>("points") ?: listOf()
                    val pointsArrayList = ArrayList<Double>()
                    for (item in rawList) {
                        if (item is Number) {
                            pointsArrayList.add(item.toDouble())
                        }
                    }
                    
                    val speed = call.argument<Double>("speed") ?: 15.0
                    val noise = call.argument<Boolean>("noise") ?: true
                    val healthSteps = call.argument<Boolean>("healthSteps") ?: false
                    val stepsPerMeter = call.argument<Double>("stepsPerMeter") ?: 1.1
                    
                    val enableLoop = call.argument<Boolean>("enableLoop") ?: false
                    val loopTimes = call.argument<Int>("loopTimes") ?: -1
                    val isRoundTrip = call.argument<Boolean>("isRoundTrip") ?: true

                    MockLocationService.startService(
                        this, 
                        pointsArrayList, 
                        speed, 
                        noise, 
                        healthSteps, 
                        stepsPerMeter,
                        enableLoop,
                        loopTimes,
                        isRoundTrip
                    )
                    result.success(true)
                }
                "stopNativeService" -> {
                    MockLocationService.stopService(this)
                    result.success(true)
                }
                "updateServiceSettings" -> {
                    val isPaused = call.argument<Boolean>("isPaused") ?: false
                    val speed = call.argument<Double>("speed") ?: 15.0
                    val noise = call.argument<Boolean>("noise") ?: true
                    val healthSteps = call.argument<Boolean>("healthSteps") ?: false
                    val stepsPerMeter = call.argument<Double>("stepsPerMeter") ?: 1.1
                    
                    val enableLoop = call.argument<Boolean>("enableLoop") ?: false
                    val loopTimes = call.argument<Int>("loopTimes") ?: -1
                    val isRoundTrip = call.argument<Boolean>("isRoundTrip") ?: true

                    MockLocationService.updateSettings(
                        this, 
                        isPaused, 
                        speed, 
                        noise, 
                        healthSteps, 
                        stepsPerMeter,
                        enableLoop,
                        loopTimes,
                        isRoundTrip
                    )
                    result.success(true)
                }
                "checkServiceState" -> {
                    val manager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                    var isSimulating = false
                    for (service in manager.getRunningServices(Int.MAX_VALUE)) {
                        if (MockLocationService::class.java.name == service.service.className) {
                            isSimulating = true
                            break
                        }
                    }

                    val response = mutableMapOf<String, Any>(
                        "isSimulating" to isSimulating,
                        "isPaused" to MockLocationService.isServicePaused
                    )

                    if (isSimulating) {
                        response["points"] = MockLocationService.activeRoutePoints
                        response["speed"] = MockLocationService.activeSpeed
                        response["noise"] = MockLocationService.activeNoise
                        response["healthSteps"] = MockLocationService.activeHealthSteps
                        response["stepsPerMeter"] = MockLocationService.activeStepsPerMeter
                        response["enableLoop"] = MockLocationService.activeEnableLoop
                        response["loopTimes"] = MockLocationService.activeLoopTimes
                        response["isRoundTrip"] = MockLocationService.activeIsRoundTrip
                    }

                    result.success(response)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        channel = null
        super.onDestroy()
    }
}