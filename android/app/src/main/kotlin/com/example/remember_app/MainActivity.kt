package com.example.remember_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
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
                // 标记某条通知已被用户手动补记，避免重复点出两条账单。
                "markNotificationRecorded" -> {
                    val ts = (call.argument<Number>("timestamp"))?.toLong() ?: 0L
                    result.success(ListenerDiagnostics.markRecorded(this, ts))
                }
                // 手动重连监听服务。
                //
                // 必须放到后台线程：重连过程要等 onListenerConnected，
                // 而那个回调是主线程派发的，主线程被占住就永远等不到。
                "reconnectListener" -> {
                    val appContext = applicationContext
                    Log.i(TAG, "收到 reconnectListener 请求")
                    // 必须显式 start()：Kotlin 的 `Thread { ... }` 走的是
                    // `java.lang.Thread(Runnable)` 构造器，只创建不启动，
                    // 忘了 start() 的话线程体永远不跑，结果也就永远回不去。
                    val worker = Thread({
                        try {
                            val payload = reconnectListener(appContext)
                            Log.i(TAG, "reconnectListener 完成：${payload["stage"]}")
                            // 用主 Looper 而不是 runOnUiThread：
                            // 期间 Activity 可能已经销毁，那样就再也回不了结果。
                            Handler(Looper.getMainLooper()).post { result.success(payload) }
                        } catch (e: Throwable) {
                            Log.e(TAG, "reconnectListener 出错", e)
                            Handler(Looper.getMainLooper()).post {
                                result.error(
                                    "reconnect_failed",
                                    e.message ?: e.javaClass.simpleName,
                                    null
                                )
                            }
                        }
                    }, "listener-reconnect")
                    worker.start()
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

    override fun onResume() {
        super.onResume()
        // 回到前台时：排上保活闹钟，并顺手请求一次重新绑定。
        //
        // 用户打开 App 就说明进程刚起来，系统这时通常会重新绑定监听服务；
        // 主动请求一次可以让「打开 App 就恢复正常」这件事立刻发生，
        // 而不是等下一次闹钟。
        ListenerKeepAlive.schedule(applicationContext)
        ListenerKeepAlive.rebind(applicationContext)
    }

    override fun onDestroy() {
        eventSink = null
        PaymentEvents.listener = null
        super.onDestroy()
    }

    /**
     * 手动重连监听服务。
     *
     * 结果会写进诊断存储，用户下次打开 App 还能看到「上次重连的结果是什么」，
     * 不用只靠一闪而过的提示框。
     *
     * @return 形如 mapOf("ok" to true, "stage" to "rebind"/"force", "message" to "...")
     */
    private fun reconnectListener(appContext: Context): Map<String, Any?> {
        val result = doReconnect(appContext)
        ListenerDiagnostics.recordReconnect(
            appContext,
            result["ok"] as? Boolean ?: false,
            result["stage"] as? String ?: "unknown",
            result["message"] as? String ?: ""
        )
        return result
    }

    /**
     * 重连的实际动作。
     *
     * 分两步，先轻后重：
     * 1. 先用无副作用的 `requestRebind` 请求重绑，等几秒看有没有真的连上；
     * 2. 只有确实没连上，才去重置组件绑定（disable -> enable）。
     *
     * 第 2 步有副作用（系统可能临时拉黑反复绑定失败的监听器），
     * 所以先判断「绑定到底还活着没有」：
     * - 刚刚还在收到通知 -> 绑定是活的，只重绑就够了；
     * - 很久没收到任何通知 -> 绑定多半已经僵死，才需要重置组件。
     *
     * **必须在后台线程执行**：`onListenerConnected` 是主线程回调的，
     * 主线程要是被这里占住等它，就永远等不到（死等）。
     */
    private fun doReconnect(appContext: Context): Map<String, Any?> {
        if (!PaymentNotificationListenerService.isNotificationListeningEnabled(appContext)) {
            return mapOf(
                "ok" to false,
                "stage" to "notAuthorized",
                "message" to "系统设置里的「通知使用权」没有勾上，请先重新授权"
            )
        }

        val before = ListenerDiagnostics.snapshot(appContext, true)
        val connectedBefore = (before["serviceConnectedAt"] as? Long) ?: 0L
        val disconnectedAt = (before["serviceDisconnectedAt"] as? Long) ?: 0L
        val lastEventAt = (before["lastEventAt"] as? Long) ?: 0L
        val now = System.currentTimeMillis()

        // 最后一次事件是「断开」——这正是用户报的「用几天就失效」的指纹。
        val knownDead = ListenerHealth.isKnownDead(connectedBefore, disconnectedAt)
        // 最近还收到过任意一条通知——服务肯定还活着。
        val recentlyAlive = ListenerHealth.isRecentlyAlive(lastEventAt, now)
        Log.i(TAG, "doReconnect 开始：knownDead=$knownDead, recentlyAlive=$recentlyAlive")

        ListenerKeepAlive.rebind(appContext)
        ListenerKeepAlive.schedule(appContext)

        // 绑定看起来还活着（刚刚还在收通知）-> 只重绑，不碰组件。
        //
        // 这种情况下问题多半不在绑定，而在「通知文案没被认出来」，
        // 所以提示用户去看下面的通知记录，而不是傻等 6 秒再重置组件。
        if (recentlyAlive) {
            return mapOf(
                "ok" to true,
                "stage" to "rebind",
                "message" to "监听服务还活着（刚刚收到过通知），已重新请求连接。" +
                    "如果支付通知仍没记账，请看下方「最近收到的通知」"
            )
        }

        // 给系统一点时间重新绑定。
        //
        // 注意：绑定一直健康时，requestRebind 并不会再次触发 onListenerConnected，
        // 所以「事件有没有来」不能当成判据，只能当「系统确实重新绑了一遍」的旁证。
        val deadline = now + REBIND_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(300)
            val current = ListenerDiagnostics.snapshot(appContext, true)
            val connectedNow = (current["serviceConnectedAt"] as? Long) ?: 0L
            if (connectedNow > connectedBefore) {
                return mapOf(
                    "ok" to true,
                    "stage" to "rebind",
                    "message" to "已重新连接监听服务"
                )
            }
        }

        // 到这一步还没动静，按「绑定僵死」处理，重置组件绑定。
        Log.w(TAG, "requestRebind 未见回执，改用重置组件的方式（knownDead=$knownDead）")
        val forced = ListenerKeepAlive.forceReconnect(appContext)
        val message = when {
            !forced -> "重连失败，请确认系统设置里「通知使用权」仍然勾着"
            knownDead -> "系统之前确实断开过监听绑定，已重置绑定，请稍候再刷新看看"
            else -> "已重置监听服务绑定，请稍候再刷新看看"
        }
        return mapOf(
            "ok" to forced,
            "stage" to "force",
            "message" to message
        )
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
        private const val TAG = "PaymentListener"
        private const val CHANNEL = "remember/payment_listener"
        private const val EVENT_CHANNEL = "remember/payment_events"

        /** 等系统回应「重新绑定」的最长时间。 */
        private const val REBIND_WAIT_MS = 6000L
    }
}
