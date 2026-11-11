package com.geofencekit.core.plugin

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.geofencekit.core.engine.FenceGeo
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * geofence_kit platform plugin (Android) — OPEN-SOURCE channel glue.
 *
 * This is the one Kotlin file that ships as SOURCE inside the pub package.
 * Flutter's plugin tooling requires the class named by `pluginClass` in
 * pubspec.yaml to exist as a source file at a fixed path in the plugin — 
 * so the channel and permission layer is the readable, auditable face of the plugin.
 *
 */
class GeofenceKitPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, Application.ActivityLifecycleCallbacks {

    companion object {
        private const val METHODS_CHANNEL = "geofence_kit/methods"
        private const val EVENTS_CHANNEL = "geofence_kit/events"
        private const val REQUEST_CODE = 51051
        private const val START_REPLY_TIMEOUT_MS = 120_000L
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var appContext: Context? = null

    // Activity / permission ladder.
    private var activity: Activity? = null
    private var permissionStage = 0
    private var pendingStart: PendingStart? = null
    private val timeoutHandler = Handler(Looper.getMainLooper())

    private class PendingStart(
        val fences: List<FenceGeo>,
        val adaptive: Map<String, Any?>,
        val showDebugNotification: Boolean,
        val result: MethodChannel.Result,
    ) {
        var timedOut = false
    }

    // MARK: FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        EngineHost.attach(binding.applicationContext)
        // Foreground tracking: register with the Application (the platform's
        // ActivityLifecycleCallbacks — Flutter's embedding has no equivalent).
        (binding.applicationContext as? Application)
            ?.registerActivityLifecycleCallbacks(this)
        methodChannel = MethodChannel(binding.binaryMessenger, METHODS_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        (appContext as? Application)?.unregisterActivityLifecycleCallbacks(this)
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        EngineHost.onFlutterSinkGone()
        appContext = null
    }

    // MARK: MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "stop" -> {
                val ctx = appContext ?: bindinglessContext()
                if (ctx == null) {
                    result.error("NO_CONTEXT", "application context unavailable", null)
                    return
                }
                EngineHost.stopTracking(ctx)
                result.success(null)
            }
            "engineStateSnapshot" -> {
                val ctx = appContext ?: bindinglessContext()
                if (ctx == null) {
                    result.success(mapOf("running" to false))
                    return
                }
                EngineHost.snapshot(ctx) { snap -> result.success(snap) }
            }
            "flushOutbox" -> {
                EngineHost.flushOutbox()
                result.success(null)
            }
            "ackEvents" -> {
                // Dart-side outbox acknowledgement — ids of
                // events the application finished processing.
                val ids = call.argument<List<String>>("ids") ?: emptyList()
                EngineHost.ackEvents(ids) { acknowledged ->
                    result.success(mapOf("acknowledged" to acknowledged))
                }
            }
            "permissionStatus" -> result.success(permissionStatusMap())
            "openAppSettings" -> {
                val ctx = activity ?: appContext
                val opened = ctx != null && OemHelper.openAppDetails(ctx)
                result.success(mapOf("opened" to opened))
            }
            "requestOemAutostart" -> {
                val ctx = activity ?: appContext
                if (ctx == null) {
                    result.error("NO_CONTEXT", "application context unavailable", null)
                } else {
                    result.success(OemHelper.requestOemAutostart(ctx))
                }
            }
            // The two-handle headless registration — the
            // plugin's internal bootstrap (executed by the spawned engine)
            // + the application's task callback (resolved inside the
            // isolate). Persisted natively; survives reboots and app death.
            "enableHeadlessTask" -> {
                val ctx = appContext ?: bindinglessContext()
                if (ctx == null) {
                    result.error("NO_CONTEXT", "application context unavailable", null)
                    return
                }
                val bootstrap = call.argument<Number>("bootstrapHandle")?.toLong()
                val user = call.argument<Number>("userHandle")?.toLong()
                if (bootstrap == null || user == null) {
                    result.error("BAD_ARGS", "bootstrapHandle/userHandle missing", null)
                    return
                }
                HeadlessDispatcher.register(ctx, bootstrap, user)
                result.success(mapOf("supported" to true, "registered" to true))
            }
            // The headless isolate's bootstrap asks for its config —
            // the user-callback raw handle it must resolve + invoke.
            "headlessConfig" -> {
                val ctx = appContext ?: bindinglessContext()
                if (ctx == null) {
                    result.error("NO_CONTEXT", "application context unavailable", null)
                    return
                }
                result.success(
                    mapOf("userCallbackHandle" to HeadlessDispatcher.userCallbackHandle(ctx)),
                )
            }
            // The headless isolate finished its drain — destroy the
            // spawned engine (idle grace or the Dart-side cap fired).
            "headlessComplete" -> {
                HeadlessDispatcher.complete()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun bindinglessContext(): Context? = activity?.applicationContext

    /** Platform-normalized permission map:
     *  location / locationBackground / motion / notifications. */
    private fun permissionStatusMap(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "location" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
        "locationBackground" to (
            Build.VERSION.SDK_INT < 29 ||
                granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            ),
        "motion" to (
            Build.VERSION.SDK_INT < 29 ||
                granted(Manifest.permission.ACTIVITY_RECOGNITION)
            ),
        "notifications" to (
            Build.VERSION.SDK_INT < 33 ||
                granted(Manifest.permission.POST_NOTIFICATIONS)
            ),
    )

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: bindinglessContext()
        if (ctx == null) {
            result.error("NO_CONTEXT", "application context unavailable", null)
            return
        }
        val fences = (call.argument<List<Map<String, Any?>>>("fences") ?: emptyList())
            .mapNotNull { m ->
                val id = m["id"] as? String ?: return@mapNotNull null
                FenceGeo(
                    id = id,
                    latitude = (m["latitude"] as? Number)?.toDouble() ?: return@mapNotNull null,
                    longitude = (m["longitude"] as? Number)?.toDouble() ?: return@mapNotNull null,
                    radiusMeters = (m["radiusMeters"] as? Number)?.toDouble()
                        ?: return@mapNotNull null,
                    // Optional fields — absent for legacy callers.
                    vertices = (m["vertices"] as? List<*>)?.mapNotNull { v ->
                        (v as? List<*>)?.let { pair ->
                            val lat = (pair.getOrNull(0) as? Number)?.toDouble()
                            val lng = (pair.getOrNull(1) as? Number)?.toDouble()
                            if (lat != null && lng != null) listOf(lat, lng) else null
                        }
                    } ?: emptyList(),
                    notifyOnEnter = (m["notifyOnEnter"] as? Boolean) ?: true,
                    notifyOnExit = (m["notifyOnExit"] as? Boolean) ?: true,
                    notifyOnDwell = (m["notifyOnDwell"] as? Boolean) ?: true,
                    extras = stringKeyedMap(m["extras"]),
                )
            }
        val adaptive: Map<String, Any?> = call.argument<Map<String, Any?>>("adaptive") ?: emptyMap()
        // The single notification knob replaces the whole
        // EventNotifications map (default false — the plugin is silent).
        val showDebugNotification = call.argument<Boolean>("showDebugNotification") ?: false

        pendingStart = PendingStart(fences, adaptive, showDebugNotification, result)
        permissionStage = 0
        scheduleStartTimeout()
        beginPermissionLadder()
    }

    /**
     * Extras arrive from Dart as a StandardMethodCodec HashMap<Object, Object>
     * — the typed `as? Map<String, Any?>` is erased at runtime (kotlinc warns
     * UNCHECKED_CAST at every such site) and would have trusted non-String
     * keys until they detonate in a consumer. This performs the one check
     * the erased cast could not: every key is verified to be a String. A
     * payload that fails it (or is not a map at all) rejects the fence —
     * the same mapNotNull-drop as any other malformed field.
     */
    private fun stringKeyedMap(value: Any?): Map<String, Any?>? {
        val raw = value as? Map<*, *> ?: return null
        val out = LinkedHashMap<String, Any?>(raw.size)
        for ((k, v) in raw) {
            if (k !is String) return null
            out[k] = v
        }
        return out
    }

    // MARK: Permission ladder (fine + notifications → background on 10+)

    private fun granted(permission: String): Boolean =
        (activity ?: appContext)?.checkSelfPermission(permission) ==
            PackageManager.PERMISSION_GRANTED

    /** The background-location truth for the start reply. */
    private fun backgroundLocationGrantedNow(): Boolean =
        Build.VERSION.SDK_INT < 29 || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    private fun beginPermissionLadder() {
        val act = activity
        val fineGranted = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        if (fineGranted) {
            permissionStage = 1
            stageBackground()
            return
        }
        if (act == null || act.isFinishing) {
            // Headless attach without an activity — report and let the host
            // re-start from a UI-attached context.
            finishStart(started = false, registered = 0, message = "NO_ACTIVITY_PERMISSION")
            return
        }
        val want = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION)
        // Activity recognition is a RUNTIME permission on API 29+ — the
        // manifest declaration alone never prompts. Without the grant the
        // motion governor's ActivityRecognition registration fails (its
        // Task completes with SecurityException, never delivering a single
        // transition), so it belongs in the FIRST permission round, next to
        // fine location.
        if (Build.VERSION.SDK_INT >= 29 &&
            !granted(Manifest.permission.ACTIVITY_RECOGNITION)
        ) {
            want.add(Manifest.permission.ACTIVITY_RECOGNITION)
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            !granted(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            want.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        permissionStage = 1
        act.requestPermissions(want.toTypedArray(), REQUEST_CODE)
    }

    private fun stageBackground() {
        val pending = pendingStart
        if (pending == null || pending.timedOut) return
        val fineGranted = granted(Manifest.permission.ACCESS_FINE_LOCATION)
        if (!fineGranted) {
            finishStart(started = false, registered = 0, message = "LOCATION_DENIED")
            return
        }
        val act = activity
        if (Build.VERSION.SDK_INT >= 29 &&
            !granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION) &&
            act != null && !act.isFinishing
        ) {
            permissionStage = 2
            // On Android 11+ this round can only offer the
            // settings route (the dialog no longer grants "Allow all the
            // time" directly). A denial here does NOT block the start —
            // foreground tracking still works — but the engine becomes
            // foreground-only, and the reply now carries
            // backgroundLocationGranted=false so the app can say so and
            // deep-link to settings (openAppSettings).
            act.requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), REQUEST_CODE)
            return
        }
        beginEngineStart()
    }

    private fun beginEngineStart() {
        val pending = pendingStart
        val ctx = appContext ?: bindinglessContext()
        if (pending == null || ctx == null) return
        if (pending.timedOut) return
        EngineHost.startTracking(ctx, pending.fences, pending.adaptive, pending.showDebugNotification) {
            started, registered, message ->
            finishStart(started, registered, message)
        }
    }

    private fun finishStart(started: Boolean, registered: Int, message: String?) {
        val pending = pendingStart ?: return
        pendingStart = null
        cancelStartTimeout()
        try {
            pending.result.success(
                mapOf(
                    "started" to started,
                    "fencesRegistered" to registered,
                    "adaptiveEngine" to started,
                    "message" to (message ?: ""),
                    // The background-location truth rides
                    // the start reply — an app that skipped "Allow all the
                    // time" must be able to tell the user that background /
                    // terminated events will not fire (and offer the settings
                    // deep-link via openAppSettings).
                    "backgroundLocationGranted" to backgroundLocationGrantedNow(),
                ),
            )
        } catch (_: IllegalStateException) {
            // Result already replied (timeout path) — safe to ignore.
        }
    }

    private fun scheduleStartTimeout() {
        val pending = pendingStart ?: return
        timeoutHandler.postDelayed({
            if (pendingStart === pending && !pending.timedOut) {
                pending.timedOut = true
                pendingStart = null
                try {
                    pending.result.success(
                        mapOf(
                            "started" to false,
                            "fencesRegistered" to 0,
                            "adaptiveEngine" to true,
                            "message" to "PERMISSION_TIMEOUT",
                            "backgroundLocationGranted" to backgroundLocationGrantedNow(),
                        ),
                    )
                } catch (_: Exception) {
                }
            }
        }, START_REPLY_TIMEOUT_MS)
    }

    private fun cancelStartTimeout() {
        timeoutHandler.removeCallbacksAndMessages(null)
    }

    // MARK: RequestPermissionsResultListener

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        if (permissionStage == 1) {
            stageBackground()
        } else {
            beginEngineStart()
        }
        return true
    }

    // MARK: StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        if (events != null) EngineHost.onFlutterSink(events)
    }

    override fun onCancel(arguments: Any?) {
        EngineHost.onFlutterSinkGone()
    }

    // MARK: ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // MARK: ActivityLifecycleCallbacks (foreground tracking → the engine
    // recomputes its preset + the notification pipeline gates on it).
    // Registered on the Application in onAttachedToEngine.

    override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}

    override fun onActivityStarted(activity: Activity) {}

    override fun onActivityResumed(activity: Activity) {
        EngineHost.appInForeground = true
        appContext?.let { EngineHost.attach(it) }
        com.geofencekit.core.engine.AdaptiveEngine.sharedOrNull()
            ?.onAppForeground()
    }

    override fun onActivityPaused(activity: Activity) {
        EngineHost.appInForeground = false
        com.geofencekit.core.engine.AdaptiveEngine.sharedOrNull()
            ?.onAppBackground()
    }

    override fun onActivityStopped(activity: Activity) {}

    override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}

    override fun onActivityDestroyed(activity: Activity) {}
}
