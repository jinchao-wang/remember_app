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
        val diagnosis = PaymentParser.diagnose(content)
        val parsed = diagnosis.result
        if (parsed == null) {
            // 不是支付通知（或者缺少金额/方向），直接忽略。
            // 但把原文和原因记下来，用户在 App 里能直接看到「为什么没记」。
            Log.d(TAG, "ignored: $content")
            if (looksFinancial(content)) {
                ListenerDiagnostics.recordNotification(
                    applicationContext,
                    sbn.packageName,
                    extractTitle(sbn.notification.extras),
                    extractBody(sbn.notification.extras),
                    false,
                    diagnosis.reason
                )
            }
            return
        }

        Log.i(TAG, "detected: type=${parsed.type} amount=${parsed.amount} from=${sbn.packageName}")
        if (looksFinancial(content)) {
            ListenerDiagnostics.recordNotification(
                applicationContext,
                sbn.packageName,
                extractTitle(sbn.notification.extras),
                extractBody(sbn.notification.extras),
                true,
                "已识别：${parsed.type} ${parsed.amount}"
            )
        }
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

    /** 诊断展示用的标题。 */
    private fun extractTitle(extras: Bundle): String =
        extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""

    /**
     * 诊断展示用的正文。
     *
     * 取最长的那个字段：有的应用把短摘要放 text、把完整内容放 bigtext，
     * 只看 text 会让用户看到「¥31.31」这种没头没尾的片段。
     */
    private fun extractBody(extras: Bundle): String {
        val candidates = listOf(
            Notification.EXTRA_BIG_TEXT,
            Notification.EXTRA_TEXT,
            Notification.EXTRA_SUB_TEXT,
            Notification.EXTRA_INFO_TEXT,
        ).mapNotNull { key ->
            extras.getCharSequence(key)?.toString()?.trim()
        }.filter { it.isNotEmpty() }
        return candidates.maxByOrNull { it.length } ?: ""
    }

    /**
     * 只记录「疑似支付类」的通知。
     *
     * 全量记录会把聊天消息也存下来，既没必要也不该；
     * 而带金额或带「元/¥」的通知基本就是支付提醒，正是用户要排查的那类。
     */
    private fun looksFinancial(content: String): Boolean {
        if (AMOUNT_PATTERN.containsMatchIn(content)) return true
        return content.contains("元") || content.contains("¥") || content.contains("￥")
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        ListenerDiagnostics.recordConnected(applicationContext)
        Log.i(TAG, "通知监听已连接")
    }

    override fun onListenerDisconnected() {
        ListenerDiagnostics.recordDisconnected(applicationContext)
        super.onListenerDisconnected()
        Log.w(TAG, "通知监听已断开")
    }

    companion object {
        private const val TAG = "PaymentListener"

        /** 形如 31.31 / 1,234.56 的金额。 */
        private val AMOUNT_PATTERN = Regex("""\d{1,9}(?:,\d{3})*\.\d{2}""")

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
