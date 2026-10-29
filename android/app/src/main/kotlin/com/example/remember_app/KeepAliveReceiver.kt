package com.example.remember_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 保活闹钟的接收端。
 *
 * 闹钟一到就把进程拉起来，检查监听服务还活着没有，必要时分级修复，
 * 然后排下一次闹钟。
 *
 * 用一次性闹钟 + 自我续期，而不是 `setRepeating`：
 * 前者在 Doze 下也能被 `setAndAllowWhileIdle` 准点唤醒，
 * 后者在 Doze 下会被无限期推迟。
 */
class KeepAliveReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val appContext = context.applicationContext
        Log.i(TAG, "保活闹钟触发，检查监听服务状态")
        // 交给看门狗分级处理：活着就轻量重绑，僵死了才动组件。
        // 这里不用 goAsync()，看门狗内部的动作都是短平快的系统调用。
        //
        // 兜住异常：广播接收器和 App 在同一个进程里，
        // 这里抛出 = 整个 App 进程猝死（用户在后台收到通知时崩溃）。
        try {
            ListenerWatchdog.checkAndRepair(appContext, "alarm")
        } catch (e: Throwable) {
            Log.w(TAG, "保活闹钟处理失败: $e")
        }
    }

    companion object {
        private const val TAG = "KeepAlive"

        /** 闹钟广播的 action。 */
        const val ACTION_KEEP_ALIVE = "com.example.remember_app.action.KEEP_ALIVE"
    }
}
