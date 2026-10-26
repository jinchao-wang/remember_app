package com.example.remember_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 保活闹钟的接收端。
 *
 * 闹钟一到就把进程拉起来，请求系统重新绑定监听服务，然后排下一次闹钟。
 *
 * 用一次性闹钟 + 自我续期，而不是 `setRepeating`：
 * 前者在 Doze 下也能被 `setAndAllowWhileIdle` 准点唤醒，
 * 后者在 Doze 下会被无限期推迟。
 */
class KeepAliveReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val appContext = context.applicationContext
        Log.i(TAG, "保活闹钟触发，请求重新绑定监听服务")
        ListenerKeepAlive.rebind(appContext)
        // 续期，保证下一次闹钟存在。
        ListenerKeepAlive.schedule(appContext)
    }

    companion object {
        private const val TAG = "KeepAlive"

        /** 闹钟广播的 action。 */
        const val ACTION_KEEP_ALIVE = "com.example.remember_app.action.KEEP_ALIVE"
    }
}
