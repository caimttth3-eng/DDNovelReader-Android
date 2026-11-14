package com.ddnovelreader

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Activity-aware bridge retained by audio_service's shared FlutterEngine. */
class NotificationPermissionPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener,
    Application.ActivityLifecycleCallbacks {
    companion object {
        private const val REQUEST_CODE = 0xDD31
        private const val CHANNEL_ID = "com.ddnovelreader.tts"
        private const val PREFS = "notification_permission"
        private const val ASKED = "post_notifications_asked"
    }

    private lateinit var application: Application
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var resumed = false
    private val pending = mutableListOf<MethodChannel.Result>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        application = binding.applicationContext as Application
        application.registerActivityLifecycleCallbacks(this)
        channel = MethodChannel(binding.binaryMessenger, "com.ddnovelreader/notifications").also {
            it.setMethodCallHandler(this)
        }
    }

    private fun hasPermission(): Boolean = Build.VERSION.SDK_INT < 33 ||
        application.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun channelEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return true
        val manager = application.getSystemService(NotificationManager::class.java)
        return manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun isForeground(): Boolean {
        val host = activity ?: return false
        return resumed && !host.isFinishing && !host.isDestroyed
    }

    private fun status(): Map<String, Boolean> {
        val asked = application.getSharedPreferences(PREFS, 0).getBoolean(ASKED, false)
        return mapOf(
            "supported" to true,
            "enabled" to (NotificationManagerCompat.from(application).areNotificationsEnabled() && channelEnabled()),
            "canRequest" to (Build.VERSION.SDK_INT >= 33 && !hasPermission() && !asked && isForeground()),
            "asked" to asked
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getNotificationStatus" -> result.success(status())
            "requestNotificationPermission" -> requestPermission(result)
            "openNotificationSettings" -> result.success(openSettings())
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        // Coalesce duplicate calls while the system dialog is already visible.
        if (pending.isNotEmpty()) { pending.add(result); return }
        val host = activity
        if (Build.VERSION.SDK_INT < 33 || host == null || status()["canRequest"] != true) {
            result.success(status())
            return
        }
        // Persist before launching the dialog, including dismissals, so a new
        // Activity or a later playback session cannot repeatedly ask on denial.
        application.getSharedPreferences(PREFS, 0).edit().putBoolean(ASKED, true).apply()
        pending.add(result)
        try {
            host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
        } catch (_: RuntimeException) {
            completePending()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        completePending()
        return true
    }

    private fun completePending() {
        val results = pending.toList()
        pending.clear()
        val state = status()
        results.forEach { it.success(state) }
    }

    private fun openSettings(): Boolean {
        val host = activity ?: return false
        if (!isForeground()) return false
        val intent = when {
            Build.VERSION.SDK_INT >= 26 && NotificationManagerCompat.from(application).areNotificationsEnabled() && !channelEnabled() ->
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, application.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
            Build.VERSION.SDK_INT >= 26 -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, application.packageName)
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${application.packageName}"))
        }
        return try {
            host.startActivity(intent)
            true
        } catch (_: RuntimeException) {
            try {
                host.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${application.packageName}")))
                true
            } catch (_: RuntimeException) { false }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        activity = binding.activity
        resumed = false
        binding.addRequestPermissionsResultListener(this)
    }

    private fun detachActivity() {
        resumed = false
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        activity = null
        // Settle the old Dart request even when Android recreates its Activity.
        // The new host and the UI's resume refresh query the eventual decision.
        completePending()
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        channel?.setMethodCallHandler(null)
        channel = null
        application.unregisterActivityLifecycleCallbacks(this)
    }

    override fun onActivityResumed(activity: Activity) { if (this.activity === activity) resumed = true }
    override fun onActivityPaused(activity: Activity) { if (this.activity === activity) resumed = false }
    override fun onActivityDestroyed(activity: Activity) { if (this.activity === activity) detachActivity() }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
}
