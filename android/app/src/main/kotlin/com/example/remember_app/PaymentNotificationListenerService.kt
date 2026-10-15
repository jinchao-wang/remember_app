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

    private val expenseKeywords = listOf("支付成功","付款成功","消费","支出","扣款","购买","下单","还款","充值")
    private val incomeKeywords = listOf("收款","到账","转入","红包")

    override fun onCreate() {
        super.onCreate()
        // 必须在任何 post() 之前初始化，否则缓存无处可写。
        PaymentEvents.init(applicationContext)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return

        val content = extractContent(sbn.notification.extras)
        if (content.isBlank()) return

        val isExpense = expenseKeywords.any { content.contains(it) }
        val isIncome = incomeKeywords.any { content.contains(it) }
        if (!isExpense && !isIncome) return

        val amount = extractAmount(content) ?: return
        val type = if (isIncome && !isExpense) TYPE_INCOME else TYPE_EXPENSE
        Log.i(TAG, "detected: type=$type amount=$amount from=${sbn.packageName}")
        PaymentEvents.post(amount, sbn.packageName, content, type, sbn.postTime)
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

    private fun extractAmount(content: String): Double? {
        // 带货币符号或「元」后缀的优先，且允许千分位。
        val symbol = Regex("""(?:¥|￥|RMB)\s*(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)|(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)\s*元""")
        symbol.find(content)?.let {
            val raw = it.groupValues[1].ifEmpty { it.groupValues[2] }
            if (raw.isNotBlank()) {
                raw.replace(",", "").toDoubleOrNull()?.let { return it }
            }
        }
        // 兜底：裸的两位小数。这里刻意不放开位数上限，
        // 否则订单号/卡号等长数字会被误当成金额。
        val plain = Regex("""\d{1,7}\.\d{2}""")
        plain.find(content)?.let {
            return it.value.replace(",", "").toDoubleOrNull()
        }
        return null
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
        private const val TYPE_EXPENSE = "expense"
        private const val TYPE_INCOME = "income"

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
