package com.example.my_mock_route

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log

import androidx.core.app.NotificationCompat
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Metadata

import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices

import java.time.Instant
import java.time.ZoneId
import java.util.Random

import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class MockLocationService : Service() {

    companion object {
        private const val TAG = "MockGPS"
        private const val CHANNEL_ID = "MockGpsForegroundChannel"
        private const val NOTIFICATION_ID = 1

        private const val ACTION_UPDATE_SETTINGS = "ACTION_UPDATE_SETTINGS"

        private const val DEFAULT_SPEED_KMH = 15.0
        private const val DEFAULT_STEPS_PER_METER = 1.1
        private const val TICK_INTERVAL_MS = 1_000L
        private const val STEP_WRITE_INTERVAL_MS = 10_000L

        private const val EARTH_RADIUS_METERS = 6_371_000.0

        @Volatile
        var isServicePaused = false
            private set

        val activeRoutePoints = ArrayList<Double>()

        @Volatile
        var activeSpeed: Double = DEFAULT_SPEED_KMH

        @Volatile
        var activeNoise: Boolean = true

        @Volatile
        var activeHealthSteps: Boolean = false

        @Volatile
        var activeStepsPerMeter: Double = DEFAULT_STEPS_PER_METER

        @Volatile
        var activeEnableLoop: Boolean = true

        @Volatile
        var activeLoopTimes: Int = -1

        @Volatile
        var activeIsRoundTrip: Boolean = true

        fun startService(
            context: Context,
            points: ArrayList<Double>,
            speedKmH: Double,
            noise: Boolean,
            healthSteps: Boolean,
            stepsPerMeter: Double,
            enableLoop: Boolean,
            loopTimes: Int,
            isRoundTrip: Boolean
        ) {
            val intent = Intent(
                context,
                MockLocationService::class.java
            ).apply {
                putExtra("points", points)
                putExtra("speed", speedKmH)
                putExtra("noise", noise)
                putExtra("healthSteps", healthSteps)
                putExtra("stepsPerMeter", stepsPerMeter)
                putExtra("enableLoop", enableLoop)
                putExtra("loopTimes", loopTimes)
                putExtra("isRoundTrip", isRoundTrip)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopService(context: Context) {
            context.stopService(
                Intent(context, MockLocationService::class.java)
            )
        }

        fun updateSettings(
            context: Context,
            isPaused: Boolean,
            speedKmH: Double,
            noise: Boolean,
            healthSteps: Boolean,
            stepsPerMeter: Double,
            enableLoop: Boolean,
            loopTimes: Int,
            isRoundTrip: Boolean
        ) {
            val intent = Intent(context, MockLocationService::class.java).apply {
                action = ACTION_UPDATE_SETTINGS
                putExtra("isPaused", isPaused)
                putExtra("speed", speedKmH)
                putExtra("noise", noise)
                putExtra("healthSteps", healthSteps)
                putExtra("stepsPerMeter", stepsPerMeter)
                putExtra("enableLoop", enableLoop)
                putExtra("loopTimes", loopTimes)
                putExtra("isRoundTrip", isRoundTrip)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    private lateinit var fusedClient: FusedLocationProviderClient
    private lateinit var locationManager: LocationManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val healthWriteMutex = Mutex()
    private val random = Random()

    // Simulation lifecycle
    private var isSimulating = false
    private var isStarting = false
    private var isPaused = false
    private var routeFinished = false
    private var hasCurrentLocation = false
    private var providerRegistered = false

    // Route
    private val routePoints =
        mutableListOf<Pair<Double, Double>>()

    private var currentSegmentIndex = 0
    private var currentLat = 0.0
    private var currentLng = 0.0

    // Speed is stored internally in meters per second.
    private var speedMps = DEFAULT_SPEED_KMH / 3.6

    // Settings
    private var enableHealthConnectSteps = false
    private var stepsPerMeter = DEFAULT_STEPS_PER_METER
    private var enableNoise = true

    // Loop settings
    private var enableLoop = false
    private var loopTimes = -1
    private var isRoundTrip = true
    private var isGoingForward = true
    private var completedLoops = 0

    // Last reported motion
    private var lastBearing = 0f

    // Health Connect accounting
    private var accumulatedSteps = 0.0
    private var accumulatedDistance = 0.0
    private var lastStepWriteElapsedMs = 0L

    // Exactly one location-loop runnable is retained.
    private var locationRunnable: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        fusedClient = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        // A foreground service must promote itself promptly, including
        // when it is started with an update-settings action.
        startForeground(
            NOTIFICATION_ID,
            createNotification()
        )

        if (intent?.action == ACTION_UPDATE_SETTINGS) {
            applySettings(intent)
            return START_STICKY
        }

        if (intent != null) {
            val flatPoints = readRoutePoints(intent)

            if (flatPoints == null) {
                Log.e(TAG, "Missing route points")
                sendStartFailedToFlutter("Missing route points")
                stopSelf(startId)
                return START_NOT_STICKY
            }

            if (flatPoints.size < 2 || flatPoints.size % 2 != 0) {
                Log.e(TAG, "Route must contain complete latitude/longitude pairs")
                sendStartFailedToFlutter("Invalid route: expected latitude/longitude pairs")
                stopSelf(startId)
                return START_NOT_STICKY
            }

            val parsedPoints = flatPoints
                .chunked(2)
                .map { pair ->
                    Pair(pair[0], pair[1])
                }

            if (parsedPoints.any { !isValidCoordinate(it.first, it.second) }) {
                Log.e(TAG, "Route contains invalid coordinates")
                sendStartFailedToFlutter("Invalid route coordinates")
                stopSelf(startId)
                return START_NOT_STICKY
            }

            activeRoutePoints.clear()
            activeRoutePoints.addAll(flatPoints)

            routePoints.clear()
            routePoints.addAll(parsedPoints)

            applySettings(intent)

            // If already running, update the existing simulation instead
            // of registering another provider or creating another loop.
            if (isSimulating || isStarting) {
                resetRouteState()
                return START_STICKY
            }

            resetRouteState()
            startSimulation()
            return START_STICKY
        }

        // START_STICKY can restart the service with a null Intent.
        // Restore the last route/settings retained in this process.
        if (routePoints.isEmpty() && activeRoutePoints.size >= 2) {
            val points = activeRoutePoints.toList()

            if (points.size % 2 == 0) {
                routePoints.clear()
                routePoints.addAll(
                    points.chunked(2).map {
                        Pair(it[0], it[1])
                    }
                )
            }
        }

        if (routePoints.isNotEmpty() &&
            !isSimulating &&
            !isStarting
        ) {
            resetRouteState()
            startSimulation()
        }

        return START_STICKY
    }

    @Suppress("DEPRECATION")
    private fun readRoutePoints(intent: Intent): ArrayList<Double>? {
        return try {
            intent.getSerializableExtra("points") as? ArrayList<Double>
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read route points", e)
            null
        }
    }

    private fun applySettings(intent: Intent) {
        if (intent.hasExtra("isPaused")) {
            isPaused = intent.getBooleanExtra("isPaused", false)
            isServicePaused = isPaused
        }

        if (intent.hasExtra("speed")) {
            activeSpeed = intent.getDoubleExtra("speed", DEFAULT_SPEED_KMH).let {
                if (it.isFinite()) it.coerceIn(0.0, 360.0)
                else DEFAULT_SPEED_KMH
            }
            speedMps = activeSpeed / 3.6
        }

        if (intent.hasExtra("noise")) {
            activeNoise = intent.getBooleanExtra("noise", true)
            enableNoise = activeNoise
        }

        if (intent.hasExtra("healthSteps")) {
            activeHealthSteps = intent.getBooleanExtra("healthSteps", false)
            enableHealthConnectSteps = activeHealthSteps
        }

        if (intent.hasExtra("stepsPerMeter")) {
            activeStepsPerMeter = intent.getDoubleExtra("stepsPerMeter", DEFAULT_STEPS_PER_METER).let {
                if (it.isFinite()) it.coerceIn(0.0, 10.0)
                else DEFAULT_STEPS_PER_METER
            }
            stepsPerMeter = activeStepsPerMeter
        }

        if (intent.hasExtra("enableLoop")) {
            activeEnableLoop = intent.getBooleanExtra("enableLoop", false)
            enableLoop = activeEnableLoop
        }

        if (intent.hasExtra("loopTimes")) {
            activeLoopTimes = intent.getIntExtra("loopTimes", -1)
            loopTimes = activeLoopTimes
        }

        if (intent.hasExtra("isRoundTrip")) {
            activeIsRoundTrip = intent.getBooleanExtra("isRoundTrip", true)
            isRoundTrip = activeIsRoundTrip
        }
    }

    private fun resetRouteState() {
        if (routePoints.isEmpty()) return

        currentLat = routePoints.first().first
        currentLng = routePoints.first().second

        currentSegmentIndex = 0
        isGoingForward = true
        completedLoops = 0
        routeFinished = false
        hasCurrentLocation = true

        lastBearing = 0f

        accumulatedSteps = 0.0
        accumulatedDistance = 0.0
        lastStepWriteElapsedMs = SystemClock.elapsedRealtime()
    }

    private fun startSimulation() {
        if (isStarting || isSimulating) return

        if (routePoints.isEmpty()) {
            sendStartFailedToFlutter("Cannot start an empty route")
            return
        }

        isStarting = true

        try {
            // Clean up a provider left by a previous failed start.
            try {
                locationManager.setTestProviderEnabled(LocationManager.GPS_PROVIDER, false)
            } catch (_: Exception) {
                // Provider may not exist.
            }

            try {
                locationManager.removeTestProvider(LocationManager.GPS_PROVIDER)
            } catch (_: Exception) {
                // Provider may not exist.
            }

            locationManager.addTestProvider(
                LocationManager.GPS_PROVIDER,
                false,
                false,
                false,
                false,
                true,
                true,
                true,
                1,
                1
            )

            providerRegistered = true

            locationManager.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start GPS test provider", e)

            isStarting = false
            cleanupGpsProvider()

            sendStartFailedToFlutter("Failed to start GPS test provider: ${e.message}")
            return
        }

        try {
            fusedClient.setMockMode(true)
                .addOnSuccessListener {
                    isStarting = false

                    if (isDestroyed || routePoints.isEmpty()) {
                        fusedClient.setMockMode(false)
                        cleanupGpsProvider()
                        return@addOnSuccessListener
                    }

                    isSimulating = true
                    startLocationLoop(TICK_INTERVAL_MS)
                }
                .addOnFailureListener { error ->
                    Log.e(TAG, "Failed to enable fused mock mode", error)

                    isStarting = false
                    isSimulating = false

                    cleanupGpsProvider()
                    sendStartFailedToFlutter("Failed to enable fused mock mode: ${error.message}")
                }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request fused mock mode", e)

            isStarting = false
            isSimulating = false
            cleanupGpsProvider()

            sendStartFailedToFlutter("Failed to enable fused mock mode: ${e.message}")
        }
    }

    @Volatile
    private var isDestroyed = false

    private fun startLocationLoop(intervalMs: Long) {
        // Prevent duplicate runnable instances.
        locationRunnable?.let {
            handler.removeCallbacks(it)
        }

        val runnable = object : Runnable {
            override fun run() {
                if (!isSimulating || isDestroyed) return

                try {
                    tickSimulation(intervalMs)
                } catch (e: Exception) {
                    Log.e(TAG, "Location simulation tick failed", e)
                }

                if (isSimulating && !isDestroyed) {
                    handler.postDelayed(this, intervalMs)
                }
            }
        }

        locationRunnable = runnable
        handler.post(runnable)
    }

    private fun tickSimulation(intervalMs: Long) {
        if (routePoints.isEmpty() || !hasCurrentLocation) return

        val accuracy = if (enableNoise) {
            3.0 + random.nextDouble() * 9.0
        } else {
            1.5
        }

        if (isPaused) {
            pushLocation(
                currentLat,
                currentLng,
                0f,
                lastBearing,
                accuracy
            )
            return
        }

        // A single-point route has no movement or step accumulation.
        if (routePoints.size == 1) {
            val point = routePoints.first()

            currentLat = point.first
            currentLng = point.second

            pushLocation(
                currentLat,
                currentLng,
                0f,
                lastBearing,
                accuracy
            )
            return
        }

        // Keep reporting the terminal point after the route finishes.
        if (routeFinished) {
            pushLocation(
                currentLat,
                currentLng,
                0f,
                lastBearing,
                accuracy
            )
            return
        }

        val targetIndex = if (isGoingForward) {
            currentSegmentIndex + 1
        } else {
            currentSegmentIndex - 1
        }

        if (targetIndex !in routePoints.indices) {
            handleRouteBoundary(accuracy)
            return
        }

        val target = routePoints[targetIndex]
        val targetLat = target.first
        val targetLng = target.second

        val distMeters = calculateDistance(
            currentLat,
            currentLng,
            targetLat,
            targetLng
        )

        val bearing = if (distMeters > 0.001) {
            calculateBearing(
                currentLat,
                currentLng,
                targetLat,
                targetLng
            ).toFloat()
        } else {
            lastBearing
        }

        lastBearing = bearing

        val activeSpeedMps = if (enableNoise && speedMps > 0.0) {
            max(
                0.0,
                speedMps +
                    ((random.nextDouble() * 2.0 - 1.0) *
                        0.15 * speedMps)
            )
        } else {
            speedMps
        }

        val distancePerTick =
            activeSpeedMps * (intervalMs / 1000.0)

        // Use actual traveled distance, not the intended distance,
        // for step accounting.
        val actualDistance = min(
            distMeters,
            distancePerTick.coerceAtLeast(0.0)
        )

        if (distMeters <= 0.001 || distMeters <= distancePerTick) {
            currentLat = targetLat
            currentLng = targetLng
            currentSegmentIndex = targetIndex
        } else if (distancePerTick > 0.0) {
            val destination = destinationPoint(
                currentLat,
                currentLng,
                bearing.toDouble(),
                distancePerTick
            )

            currentLat = destination.first
            currentLng = destination.second
        }

        if (enableHealthConnectSteps && actualDistance > 0.0) {
            recordSimulatedDistance(actualDistance)
        }

        val noisyPoint = if (enableNoise) {
            applyPositionNoise(currentLat, currentLng)
        } else {
            Pair(currentLat, currentLng)
        }

        pushLocation(
            noisyPoint.first,
            noisyPoint.second,
            activeSpeedMps.toFloat(),
            bearing,
            accuracy
        )
    }

    private fun handleRouteBoundary(accuracy: Double) {
        if (!enableLoop) {
            routeFinished = true

            // Forward-only traversal ends at the last point.
            // Round trips end at the starting point.
            // Only when enableLoop apply isRoundTrip in current version (2026-10-17)
            val terminal = if (enableLoop && isRoundTrip) {
                routePoints.first()
            } else {
                routePoints.last()
            }

            currentLat = terminal.first
            currentLng = terminal.second

            pushLocation(
                currentLat,
                currentLng,
                0f,
                lastBearing,
                accuracy
            )
            return
        }

        if (isRoundTrip) {
            if (isGoingForward) {
                // Reached the end; start the return leg.
                isGoingForward = false
                currentSegmentIndex = routePoints.lastIndex
                return
            }

            // Reached the start; one complete round trip is finished.
            completedLoops++

            if (loopTimes > 0 && completedLoops >= loopTimes) {
                routeFinished = true
                currentSegmentIndex = 0

                val start = routePoints.first()
                currentLat = start.first
                currentLng = start.second

                pushLocation(
                    currentLat,
                    currentLng,
                    0f,
                    lastBearing,
                    accuracy
                )
                return
            }

            // Start the next round trip.
            isGoingForward = true
            currentSegmentIndex = 0
            return
        }

        // Forward-only loop: one loop completes at the endpoint.
        completedLoops++

        if (loopTimes > 0 && completedLoops >= loopTimes) {
            routeFinished = true

            val end = routePoints.last()
            currentLat = end.first
            currentLng = end.second
            currentSegmentIndex = routePoints.lastIndex

            pushLocation(
                currentLat,
                currentLng,
                0f,
                lastBearing,
                accuracy
            )
            return
        }

        // Begin the next forward traversal.
        val start = routePoints.first()

        currentLat = start.first
        currentLng = start.second
        currentSegmentIndex = 0
        isGoingForward = true
    }

    private fun recordSimulatedDistance(distanceMeters: Double) {
        if (!distanceMeters.isFinite() || distanceMeters <= 0.0) return

        accumulatedDistance += distanceMeters

        val noiseMultiplier = if (enableNoise) {
            0.8 + random.nextDouble() * 0.4
        } else {
            1.0
        }

        accumulatedSteps +=
            distanceMeters * stepsPerMeter * noiseMultiplier

        val nowElapsed = SystemClock.elapsedRealtime()

        if (nowElapsed - lastStepWriteElapsedMs <
            STEP_WRITE_INTERVAL_MS
        ) {
            return
        }

        val stepsToWrite = accumulatedSteps.toInt()
        if (stepsToWrite <= 0) return

        val durationSeconds = (
            (nowElapsed - lastStepWriteElapsedMs) / 1_000L
        ).coerceAtLeast(1L)

        // Preserve fractional steps between writes.
        accumulatedSteps -= stepsToWrite.toDouble()
        lastStepWriteElapsedMs = nowElapsed

        writeStepsToHealthConnect(
            stepCount = stepsToWrite,
            durationSeconds = durationSeconds
        )
    }

    private fun pushLocation(
        lat: Double,
        lng: Double,
        speed: Float,
        bearing: Float,
        accuracy: Double
    ) {
        if (!isValidCoordinate(lat, lng)) {
            Log.w(TAG, "Skipping invalid location: $lat, $lng")
            return
        }

        val currentTime = System.currentTimeMillis()
        val currentRealtimeNanos =
            SystemClock.elapsedRealtimeNanos()

        val location = Location(
            LocationManager.GPS_PROVIDER
        ).apply {
            latitude = lat
            longitude = lng
            this.speed = speed.coerceAtLeast(0f)
            this.bearing = ((bearing % 360f) + 360f) % 360f
            this.accuracy = accuracy.toFloat().coerceAtLeast(0.1f)
            time = currentTime
            elapsedRealtimeNanos = currentRealtimeNanos
        }

        if (providerRegistered) {
            try {
                locationManager.setTestProviderLocation(
                    LocationManager.GPS_PROVIDER,
                    location
                )
            } catch (e: Exception) {
                Log.w(TAG, "LocationManager mock update failed", e)
            }
        }

        try {
            fusedClient.setMockLocation(location)
                .addOnFailureListener {
                    Log.e(TAG, "Fused mock location update failed", it)
                }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to submit fused mock location", e)
        }

        try {
            sendLocationToFlutter(lat, lng)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send location to Flutter", e)
        }
    }

    private fun writeStepsToHealthConnect(
        stepCount: Int,
        durationSeconds: Long
    ) {
        if (stepCount <= 0 || durationSeconds <= 0L) return

        serviceScope.launch {
            healthWriteMutex.withLock {
                try {
                    val client = HealthConnectClient.getOrCreate(
                        this@MockLocationService
                    )

                    val endTime = Instant.now()
                    val startTime = endTime.minusSeconds(
                        durationSeconds.coerceAtLeast(1L)
                    )

                    val zone = ZoneId.systemDefault()
                    val zoneRules = zone.rules

                    val record = StepsRecord(
                        count = stepCount.toLong(),
                        startTime = startTime,
                        startZoneOffset = zoneRules.getOffset(startTime),
                        endTime = endTime,
                        endZoneOffset = zoneRules.getOffset(endTime),
                        metadata = Metadata.manualEntry()
                    )

                    client.insertRecords(listOf(record))

                    Log.d(
                        TAG,
                        "Health Connect: wrote $stepCount steps"
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to insert Health Connect steps", e)
                }
            }
        }
    }

    private fun applyPositionNoise(
        latitude: Double,
        longitude: Double
    ): Pair<Double, Double> {
        val noiseDistance = random.nextDouble() * 3.0
        val noiseBearing = random.nextDouble() * 2.0 * Math.PI

        val metersPerDegreeLat = 111_320.0
        val cosLatitude = cos(Math.toRadians(latitude))

        val metersPerDegreeLng =
            111_320.0 * max(abs(cosLatitude), 1e-6)

        val noisyLat = (
            latitude +
                cos(noiseBearing) *
                noiseDistance / metersPerDegreeLat
            ).coerceIn(-90.0, 90.0)

        val noisyLng = normalizeLongitude(
            longitude +
                sin(noiseBearing) *
                noiseDistance / metersPerDegreeLng
        )

        return Pair(noisyLat, noisyLng)
    }

    // Great-circle distance using the haversine formula.
    private fun calculateDistance(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ): Double {
        val lat1Rad = Math.toRadians(lat1)
        val lat2Rad = Math.toRadians(lat2)

        val dLat = lat2Rad - lat1Rad
        val dLon = Math.toRadians(
            normalizeLongitude(lon2 - lon1)
        )

        val sinLat = sin(dLat / 2.0)
        val sinLon = sin(dLon / 2.0)

        val a = (
            sinLat * sinLat +
                cos(lat1Rad) *
                cos(lat2Rad) *
                sinLon * sinLon
            ).coerceIn(0.0, 1.0)

        return EARTH_RADIUS_METERS * 2.0 * atan2(sqrt(a), sqrt(1.0 - a))
    }

    private fun calculateBearing(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ): Double {
        val startLat = Math.toRadians(lat1)
        val startLng = Math.toRadians(lon1)
        val endLat = Math.toRadians(lat2)
        val endLng = Math.toRadians(lon2)

        val dLng = endLng - startLng

        val y = sin(dLng) * cos(endLat)

        val x = (
            cos(startLat) * sin(endLat) -
                sin(startLat) *
                cos(endLat) *
                cos(dLng)
            )

        return (Math.toDegrees(atan2(y, x)) + 360.0) % 360.0
    }

    // Move along a great-circle bearing by the requested distance.
    private fun destinationPoint(
        latitude: Double,
        longitude: Double,
        bearingDegrees: Double,
        distanceMeters: Double
    ): Pair<Double, Double> {
        if (distanceMeters <= 0.0) {
            return Pair(latitude, longitude)
        }

        val angularDistance =
            distanceMeters / EARTH_RADIUS_METERS

        val bearing = Math.toRadians(bearingDegrees)
        val lat1 = Math.toRadians(latitude)
        val lon1 = Math.toRadians(longitude)

        val sinLat1 = sin(lat1)
        val cosLat1 = cos(lat1)
        val sinAngular = sin(angularDistance)
        val cosAngular = cos(angularDistance)

        val lat2 = asin(
            (
                sinLat1 * cosAngular +
                    cosLat1 * sinAngular * cos(bearing)
                ).coerceIn(-1.0, 1.0)
        )

        val lon2 = lon1 + atan2(
            sin(bearing) * sinAngular * cosLat1,
            cosAngular - sinLat1 * sin(lat2)
        )

        return Pair(
            Math.toDegrees(lat2).coerceIn(-90.0, 90.0),
            normalizeLongitude(Math.toDegrees(lon2))
        )
    }

    private fun normalizeLongitude(longitude: Double): Double {
        return ((longitude + 180.0) % 360.0 + 360.0) % 360.0 -
            180.0
    }

    private fun isValidCoordinate(
        latitude: Double,
        longitude: Double
    ): Boolean {
        return latitude.isFinite() &&
            longitude.isFinite() &&
            latitude in -90.0..90.0 &&
            longitude in -180.0..180.0
    }

    private fun cleanupGpsProvider() {
        try {
            locationManager.setTestProviderEnabled(
                LocationManager.GPS_PROVIDER,
                false
            )
        } catch (e: Exception) {
            Log.d(TAG, "GPS provider was not enabled", e)
        }

        try {
            locationManager.removeTestProvider(
                LocationManager.GPS_PROVIDER
            )
        } catch (e: Exception) {
            Log.d(TAG, "GPS provider was not registered", e)
        }

        providerRegistered = false
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Mock GPS Native Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background mock GPS route simulation"
            }

            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Mock GPS Active")
            .setContentText("Simulating route in background...")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun sendStartFailedToFlutter(errorMsg: String) {
        try {
            MainActivity.sendStartFailedToFlutter(errorMsg)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to notify Flutter of startup error", e)
        }
    }

    private fun sendLocationToFlutter(
        lat: Double,
        lng: Double
    ) {
        MainActivity.sendLocationToFlutter(lat, lng)
    }

    override fun onDestroy() {
        isDestroyed = true
        isSimulating = false
        isStarting = false
        isPaused = false
        isServicePaused = false

        locationRunnable?.let {
            handler.removeCallbacks(it)
        }
        locationRunnable = null

        handler.removeCallbacksAndMessages(null)

        try {
            fusedClient.setMockMode(false)
                .addOnFailureListener {
                    Log.e(TAG, "Failed to disable fused mock mode", it)
                }
        } catch (e: Exception) {
            Log.e(TAG, "Error disabling fused mock mode", e)
        }

        cleanupGpsProvider()

        serviceScope.cancel()

        synchronized(activeRoutePoints) {
            activeRoutePoints.clear()
        }

        routePoints.clear()

        lastBearing = 0f
        accumulatedSteps = 0.0
        accumulatedDistance = 0.0
        lastStepWriteElapsedMs = 0L

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}