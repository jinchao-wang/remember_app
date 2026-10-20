package com.example.remember_app

import android.app.Notification
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class PaymentNotificationListenerService : NotificationListenerService() {

    override fun onCreate() {
        super.onCreate()
        // 必须在任何 post() 之前初始化，否则缓存无处可写。
        PaymentEvents.init(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return

        val content = extractContent(sbn.notification.extras)
        if (content.isBlank()) return

        // 关键词匹配与金额提取都交给纯 Kotlin 的 PaymentParser，
        // 那边有 JVM 单元测试覆盖，改动不会只靠真机才发现问题。
        val parsed = PaymentParser.parse(content)
        if (parsed == null) {
            // 不是支付通知（或者缺少金额/方向），直接忽略。
            Log.d(TAG, "ignored: $content")
            return
        }

        Log.i(TAG, "detected: type=${parsed.type} amount=${parsed.amount} from=${sbn.packageName}")
        PaymentEvents.post(parsed.amount, sbn.packageName, content, parsed.type, sbn.postTime)
    }

    /**
     * 不同厂商/应用把正文放在不同字段里，只读 EXTRA_TEXT 会漏掉不少通知。
     * 这里把所有常见字段拼起来一起做关键词匹配。
     */
    private fun extractContent(extras: Bundle): String {
        val parts = listOf(
            Notification.EXTRA_TITLE,
            Notification.EXTRA_TEXT,
            Notification.EXTRA_BIG_TEXT,
            Notification.EXTRA_SUB_TEXT,
            Notification.EXTRA_INFO_TEXT,
        ).mapNotNull { key ->
            extras.getCharSequence(key)?.toString()?.trim()
        }.filter { it.isNotEmpty() }
        return parts.joinToString(" ")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "通知监听已连接")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.w(TAG, "通知监听已断开")
    }

    companion object {
        private const val TAG = "PaymentListener"

        fun isNotificationListeningEnabled(context: Context): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                val enabledListeners = Settings.Secure.getString(
                    context.contentResolver,
                    "enabled_notification_listeners"
                ) ?: return false
                return enabledListeners.contains(context.packageName)
            }
            return false
        }
    }
}
