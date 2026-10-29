package com.example.remember_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 开机自启。
 *
 * 重启后系统通常会重新绑定通知监听服务，但不保险：
 * 国产 ROM 上经常出现「重启后监听要过好几分钟才连上」甚至干脆不连的情况。
 * 这里主动排上保活闹钟并请求一次重绑。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        val appContext = context.applicationContext
        Log.i(TAG, "收到 $action，重新排保活闹钟并检查监听服务")
        ListenerKeepAlive.schedule(appContext)
        // Job 是跨重启保留的（setPersisted），闹钟会被系统清掉，两者都要排。
        ListenerWatchdogJob.schedule(appContext)
        ListenerWatchdog.checkAndRepair(appContext, "boot")
    }

    companion object {
        private const val TAG = "KeepAlive"
    }
}
