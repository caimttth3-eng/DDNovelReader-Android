package com.ddnovelreader

import android.app.Activity
import android.os.Build
import android.view.RoundedCorner
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max

/** Reports unconsumed window geometry, including when status bars are hidden. */
class DisplayCutoutPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.ddnovelreader/display_cutout").also {
            it.setMethodCallHandler(this)
        }
    }

    private fun flutterView(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) {
            flutterView(view.getChildAt(i))?.let { return it }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun geometry(): Map<String, Any>? {
        val host = activity ?: return null
        val decor = host.window.decorView
        val view = flutterView(decor) ?: return null
        if (view.width <= 0 || view.height <= 0) return null
        val density = view.resources.displayMetrics.density.toDouble()
        val origin = IntArray(2)
        view.getLocationInWindow(origin)
        val x = origin[0]
        val y = origin[1]
        val windowWidth = decor.width
        val windowHeight = decor.height
        val rootInsets = if (Build.VERSION.SDK_INT >= 23) decor.rootWindowInsets else null
        // CurrentWindowMetrics supplies the window's unconsumed insets if an
        // OEM's immersive dispatch omits the cutout from rootWindowInsets.
        val metricsInsets = if (Build.VERSION.SDK_INT >= 30) host.windowManager.currentWindowMetrics.windowInsets else null
        val insets = rootInsets ?: metricsInsets
        if (Build.VERSION.SDK_INT >= 23 && insets == null) return null
        val cutout = if (Build.VERSION.SDK_INT >= 28) rootInsets?.displayCutout ?: metricsInsets?.displayCutout else null
        val bounds = if (Build.VERSION.SDK_INT >= 28) cutout?.boundingRects.orEmpty().mapNotNull { rect ->
            val left = (rect.left - x).coerceIn(0, view.width)
            val top = (rect.top - y).coerceIn(0, view.height)
            val right = (rect.right - x).coerceIn(0, view.width)
            val bottom = (rect.bottom - y).coerceIn(0, view.height)
            if (right <= left || bottom <= top) null else mapOf(
                "left" to left / density, "top" to top / density,
                "right" to right / density, "bottom" to bottom / density)
        } else emptyList()
        val cutoutInsets = if (Build.VERSION.SDK_INT >= 30) {
            (metricsInsets ?: insets)?.getInsetsIgnoringVisibility(WindowInsets.Type.displayCutout())
        } else null
        val leftInset = if (Build.VERSION.SDK_INT >= 28) max(cutout?.safeInsetLeft ?: 0, cutoutInsets?.left ?: 0) else 0
        val topInset = if (Build.VERSION.SDK_INT >= 28) max(cutout?.safeInsetTop ?: 0, cutoutInsets?.top ?: 0) else 0
        val rightInset = if (Build.VERSION.SDK_INT >= 28) max(cutout?.safeInsetRight ?: 0, cutoutInsets?.right ?: 0) else 0
        val bottomInset = if (Build.VERSION.SDK_INT >= 28) max(cutout?.safeInsetBottom ?: 0, cutoutInsets?.bottom ?: 0) else 0
        val statusTop = if (Build.VERSION.SDK_INT >= 30) {
            (metricsInsets ?: insets)?.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars())?.top ?: 0
        } else insets?.stableInsetTop ?: 0
        val statusVisible = if (Build.VERSION.SDK_INT >= 30) {
            insets?.isVisible(WindowInsets.Type.statusBars()) ?: false
        } else {
            decor.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN == 0 &&
                host.window.attributes.flags and WindowManager.LayoutParams.FLAG_FULLSCREEN == 0
        }
        fun corner(position: Int): Double = if (Build.VERSION.SDK_INT >= 31) {
            (insets?.getRoundedCorner(position)?.radius ?: metricsInsets?.getRoundedCorner(position)?.radius ?: 0) / density
        } else 0.0
        return mapOf(
            "width" to view.width / density, "height" to view.height / density,
            "cutouts" to bounds,
            "safeInsets" to mapOf(
                "left" to max(0, leftInset - x) / density,
                "top" to max(0, topInset - y) / density,
                "right" to max(0, rightInset - (windowWidth - x - view.width)) / density,
                "bottom" to max(0, bottomInset - (windowHeight - y - view.height)) / density),
            "statusBarTop" to max(0, statusTop - y) / density,
            "statusBarVisible" to statusVisible,
            "topLeftRadius" to corner(RoundedCorner.POSITION_TOP_LEFT),
            "topRightRadius" to corner(RoundedCorner.POSITION_TOP_RIGHT))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "getDisplayCutout") result.success(geometry()) else result.notImplemented()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        activity = null
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
