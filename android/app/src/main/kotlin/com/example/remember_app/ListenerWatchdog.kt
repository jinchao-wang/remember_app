package com.example.remember_app

import android.content.Context
import android.util.Log

/**
 * 监听服务的看门狗。
 *
 * ## 之前哪里不对
 *
 * 原来的自动保活只有一件事：闹钟一到就调 `requestRebind()`。
 * 但这个 API 有个众所周知的毛病——**监听服务已经被系统解绑之后，
 * 它经常什么也不做**（官方 issue 长期未修）。
 * 真正管用的是「禁用再启用组件」，可那一招只在用户手动点按钮时才走。
 *
 * 结果就是：App 自己在后台每 15 分钟空转一次 `requestRebind`，
 * 而在「绑定僵死」这种最常见的故障上，它永远修不好。
 * 用户看到的现象正是「刚装上好使，过几天就再也收不到了」。
 *
 * ## 现在怎么做
 *
 * 分三级，代价从大到小：
 *
 * | 情况 | 判据 | 动作 |
 * | --- | --- | --- |
 * | 服务还活着 | 最近收到过任意通知 | 只 `requestRebind`（无副作用，廉价） |
 * | 没证据说它死了 | 只是很久没动静 | `requestRebind`（无副作用） |
 * | **有硬证据说它死了** | 进程被杀后再没连上 / 系统明确断开 | **重置组件**（有副作用，限频） |
 *
 * 只有第三级才会动组件，而且是**限频**的（见 [ListenerHealth.ESCALATE_MIN_INTERVAL_MS]）：
 * 这一招有副作用，系统可能把「反复绑定失败」的监听器临时拉黑，
 * 自动路径上一天最多来一次，剩下的交给用户手动点。
 */
object ListenerWatchdog {

    private const val TAG = "Watchdog"

    /**
     * 检查监听服务是否还活着，必要时分级修复。
     *
     * @param trigger 触发来源（alarm / job / app_foreground / listener_connected），
     *   只写进日志，方便排查是谁在动。
     */
    fun checkAndRepair(context: Context, trigger: String) {
        val appContext = context.applicationContext

        // 没授权就没得救，先把常驻服务也停掉，别留个没用的通知。
        if (!PaymentNotificationListenerService.isNotificationListeningEnabled(appContext)) {
            Log.w(TAG, "看门狗($trigger)：系统里没有勾选通知使用权，跳过")
            ListenerDiagnostics.recordAutoRepair(
                appContext,
                "unauthorized",
                "系统设置里没有勾选「通知使用权」"
            )
            ListenerForegroundService.stop(appContext)
            return
        }

        val snapshot = ListenerDiagnostics.snapshot(appContext, true)
        val now = System.currentTimeMillis()
        val connectedAt = (snapshot["serviceConnectedAt"] as? Long) ?: 0L
        val disconnectedAt = (snapshot["serviceDisconnectedAt"] as? Long) ?: 0L
        val lastEventAt = (snapshot["lastEventAt"] as? Long) ?: 0L
        val lastEscalateAt = (snapshot["lastEscalateAt"] as? Long) ?: 0L
        val lastKillAt = (snapshot["lastKillAt"] as? Long) ?: 0L
        val killedAt = ProcessExit.lastRecoverableKillAt(appContext)

        // 顺手记一下「进程上次是怎么没的」。
        //
        // 必须在这里查，而不是在服务的 onDestroy 里：
        // **强行停止是直接杀进程，onDestroy 根本不会回调**，
        // 写在 onDestroy 里的话，最需要被告知的那种死法反而查不到。
        // 只有 App 活着的时候才查得到退出历史——那就趁活着的时候查。
        ProcessExit.lastExit(appContext)?.let { exit ->
            if (exit.timestamp > lastKillAt) {
                ListenerDiagnostics.recordKill(appContext, exit.timestamp, exit.describe())
            }
        }

        // 常驻服务优先拉起来：进程优先级高一点，被系统回收的概率小很多。
        ListenerForegroundService.ensureRunning(appContext)

        // 第一级：刚刚还收到过通知 -> 服务是活的，问题多半在文案识别，不该动组件。
        if (ListenerHealth.isRecentlyAlive(lastEventAt, now)) {
            Log.i(TAG, "看门狗($trigger)：服务还活着，只做一次轻量重绑")
            ListenerKeepAlive.rebind(appContext)
            ListenerDiagnostics.recordAutoRepair(appContext, "alive", "监听服务还活着")
            ListenerKeepAlive.schedule(appContext)
            return
        }

        // 第三级：有硬证据表明绑定僵死了 -> 升级到重置组件。
        if (ListenerHealth.shouldEscalate(
                connectedAt = connectedAt,
                disconnectedAt = disconnectedAt,
                killedAt = killedAt,
                lastEscalateAt = lastEscalateAt,
                now = now
            )
        ) {
            Log.w(TAG, "看门狗($trigger)：判定绑定僵死，重置监听组件")
            val ok = ListenerKeepAlive.forceReconnect(appContext)
            ListenerDiagnostics.recordEscalation(appContext, ok)
            ListenerDiagnostics.recordAutoRepair(
                appContext,
                if (ok) "escalated" else "escalate_failed",
                if (ok) "已自动重置监听服务绑定" else "自动重置绑定失败"
            )
            ListenerKeepAlive.schedule(appContext)
            return
        }

        // 第二级：没有硬证据，但确实很久没动静了 -> 先做无副作用的重绑。
        Log.i(TAG, "看门狗($trigger)：长时间没收到通知，先做一次轻量重绑")
        ListenerKeepAlive.rebind(appContext)
        ListenerDiagnostics.recordAutoRepair(appContext, "rebind", "长时间没收到通知，已请求重新绑定")
        ListenerKeepAlive.schedule(appContext)
    }
}
