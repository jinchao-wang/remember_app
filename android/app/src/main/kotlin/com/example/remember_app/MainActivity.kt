package com.example.remember_app

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PaymentEvents.init(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    result.success(true)
                    // 引导用户到系统设置开启通知权限
                    openNotificationSettings()
                }
                "isListeningEnabled" -> {
                    val enabled = PaymentNotificationListenerService.isNotificationListeningEnabled(this)
                    result.success(enabled)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(true)
                }
                // 诊断信息：服务有没有真的连上、最近收到了什么通知、为什么没记。
                "getDiagnostics" -> {
                    val enabled = PaymentNotificationListenerService.isNotificationListeningEnabled(this)
                    result.success(ListenerDiagnostics.snapshot(this, enabled))
                }
                "openAppSettings" -> {
                    openAppSettings()
                    result.success(true)
                }
                "openBatteryOptimizationSettings" -> {
                    openBatteryOptimizationSettings()
                    result.success(true)
                }
                "openAutoStartSettings" -> {
                    openAutoStartSettings()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events

                    val emit: (Double, String, String, String, Long) -> Unit = { amount, sourceApp, content, type, ts ->
                        eventSink?.success(mapOf(
                            "amount" to amount,
                            "sourceApp" to sourceApp,
                            "content" to content,
                            "type" to type,
                            "timestamp" to ts
                        ))
                    }

                    PaymentEvents.listener = emit
                    // 补发 App 未运行期间积压的支付通知。
                    PaymentEvents.flushPending(emit)
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    PaymentEvents.listener = null
                }
            }
        )
    }

    override fun onDestroy() {
        eventSink = null
        PaymentEvents.listener = null
        super.onDestroy()
    }

    private fun openNotificationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } else {
            openAppSettings()
        }
    }

    /** 应用详情页：国产 ROM 的「自启动」「电池策略」入口都在这里。 */
    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.fromParts("package", packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /** 系统「电池优化」白名单列表页。 */
    private fun openBatteryOptimizationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {
                // 有些 ROM 没有这个页面，退回应用详情页。
            }
        }
        openAppSettings()
    }

    /**
     * 打开「自启动管理」页面。
     *
     * 小米 / 华为 / OPPO / vivo / 荣耀 各家的组件名都不一样，
     * 这里挨个试，都不行就退回应用详情页（多数 ROM 在那里也有入口）。
     */
    private fun openAutoStartSettings() {
        val candidates = listOf(
            // 小米 MIUI / HyperOS
            "com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity",
            // 华为 EMUI / 鸿蒙
            "com.huawei.systemmanager/com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            // 荣耀 MagicOS
            "com.hihonor.systemmanager/com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            // OPPO ColorOS
            "com.coloros.safecenter/com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter/com.coloros.safecenter.startupapp.StartupAppListActivity",
            // vivo / iQOO
            "com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure/com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
        )

        for (name in candidates) {
            val component = ComponentName.unflattenFromString(name) ?: continue
            val intent = Intent().setComponent(component)
            if (resolveActivitySafely(intent) == null) continue
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {
                // 换下一个候选。
            }
        }
        openAppSettings()
    }

    private fun resolveActivitySafely(intent: Intent) =
        try {
            packageManager.resolveActivity(intent, 0)
        } catch (_: Exception) {
            null
        }

    companion object {
        private const val CHANNEL = "remember/payment_listener"
        private const val EVENT_CHANNEL = "remember/payment_events"
    }
}
