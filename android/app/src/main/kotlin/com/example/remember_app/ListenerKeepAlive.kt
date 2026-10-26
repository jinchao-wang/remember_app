package com.example.remember_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.util.Log

/**
 * 通知监听服务的保活与自愈。
 *
 * ## 为什么要做这件事
 *
 * 按 Android 的设计，通知监听服务是**由系统绑定、理论上永远不死**的。
 * 但实际上存在一个已知缺陷：在部分设备（国产 ROM 上尤其明显）上，
 * 监听服务会被解绑之后**再也不自动绑回来**。
 * 表现就是用户报的那个问题：
 *
 * > 刚安装时一两个小时是生效的，之后所有支付通知都收不到了，重启手机才恢复。
 *
 * 社区里确认过的自愈手段有两个：
 * - `NotificationListenerService.requestRebind()`（API 24+）——
 *   官方的「请重新绑定我」，**没有副作用**，可以放心地反复调用；
 * - 把组件 disable 再 enable —— 逼系统丢掉旧绑定重新建立，
 *   能治好 requestRebind 治不了的「绑定僵死」，但**有副作用**：
 *   反复 disable 组件会让系统认为这个监听器「反复绑定失败」并临时拉黑它。
 *
 * 所以这里分层做：
 * 1. **自动路径只走 requestRebind**：定时闹钟把进程拉起来 + 断线立即重连；
 * 2. **组件重置只由用户手动触发**（[forceReconnect]），且只在
 *    requestRebind 实测没连上时才用。
 */
object ListenerKeepAlive {

    private const val TAG = "KeepAlive"

    /**
     * 闹钟间隔：15 分钟。
     *
     * Doze 下 `setAndAllowWhileIdle` 本身也有 9~15 分钟的下限，
     * 取 15 分钟既不频繁，也不至于让用户等太久。
     */
    const val INTERVAL_MS = 15L * 60 * 1000

    private const val REQUEST_CODE = 20260101

    /** 监听服务组件。 */
    fun component(context: Context): ComponentName =
        ComponentName(context, PaymentNotificationListenerService::class.java)

    /**
     * 排一个周期闹钟，把进程拉起来请求重新绑定。
     *
     * 闹钟在设备重启后会被清掉，由 [BootReceiver] 重新排上；
     * App 被「强制停止」时系统也会清掉闹钟，用户下次打开 App 时会重新排。
     */
    fun schedule(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pi = pendingIntent(context)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // setAndAllowWhileIdle 在 Doze 下也能被唤醒，且不需要精确闹钟权限。
                am.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + INTERVAL_MS,
                    pi
                )
            } else {
                am.setInexactRepeating(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + INTERVAL_MS,
                    INTERVAL_MS,
                    pi
                )
            }
            ListenerDiagnostics.recordKeepAlive(context, true)
        } catch (e: Exception) {
            Log.w(TAG, "排保活闹钟失败: $e")
            ListenerDiagnostics.recordKeepAlive(context, false)
        }
    }

    /** 取消保活闹钟。 */
    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        try {
            am.cancel(pendingIntent(context))
        } catch (e: Exception) {
            Log.w(TAG, "取消保活闹钟失败: $e")
        }
        ListenerDiagnostics.recordKeepAlive(context, false)
    }

    /**
     * 请求系统重新绑定监听服务。
     *
     * API 24 起用官方的 `requestRebind`；更早的版本没有这个 API，
     * 只能用「启用组件」逼系统重新绑定。
     *
     * @return 是否成功发出了重绑请求。
     */
    fun rebind(context: Context): Boolean {
        val component = component(context)
        var ok = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                NotificationListenerService.requestRebind(component)
                ok = true
            } catch (e: Throwable) {
                Log.w(TAG, "requestRebind 失败: $e")
            }
        } else {
            ok = setComponentEnabled(context, component, PackageManager.COMPONENT_ENABLED_STATE_ENABLED)
        }
        Log.i(TAG, "已请求重新绑定监听服务 ok=$ok")
        ListenerDiagnostics.recordRebind(context, ok)
        return ok
    }

    /**
     * 强制重置绑定：先把组件禁用再启用，逼系统丢掉旧绑定重新建立。
     *
     * **只应在 requestRebind 实测没连上时使用**——
     * 反复禁用组件会让系统临时拉黑这个监听器。
     */
    fun forceReconnect(context: Context): Boolean {
        val component = component(context)
        val pm = context.packageManager
        try {
            pm.setComponentEnabledSetting(
                component,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            pm.setComponentEnabledSetting(
                component,
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )
        } catch (e: Exception) {
            Log.w(TAG, "重置监听组件失败: $e")
            return false
        }
        return rebind(context)
    }

    private fun setComponentEnabled(
        context: Context,
        component: ComponentName,
        state: Int
    ): Boolean = try {
        context.packageManager.setComponentEnabledSetting(
            component,
            state,
            PackageManager.DONT_KILL_APP
        )
        true
    } catch (e: Exception) {
        Log.w(TAG, "设置组件启用状态失败: $e")
        false
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, KeepAliveReceiver::class.java)
            .setAction(KeepAliveReceiver.ACTION_KEEP_ALIVE)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
