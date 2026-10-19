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

    // 明确的方向词。注意「转账 / 转出 / 提现」是资金流出，
    // 而「收到转账 / 到账 / 退款」是流入，不能混为一谈。
    private val expenseKeywords = listOf(
        "支付成功", "付款成功", "消费", "支出", "扣款", "购买", "下单", "还款", "充值",
        "转出", "提现"
    )
    private val incomeKeywords = listOf("收款", "到账", "转入", "红包", "退款")

    /**
     * 「转账」本身不表方向：单独的「转账成功」多为转出（记支出），
     * 但「微信转账到账」是流入。若把它塞进支出词表，后一种会被误判成支出。
     */
    private val ambiguousKeywords = listOf("转账")

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
        val isAmbiguous = ambiguousKeywords.any { content.contains(it) }
        // 之前这里只有 isExpense/isIncome，导致「转账成功」「提现到卡」这类
        // 完全不记账——Dart 侧明明有「转账」分类，原生层却把它挡在门外。
        if (!isExpense && !isIncome && !isAmbiguous) return

        val amount = extractAmount(content) ?: return
        val type = resolveType(isExpense, isIncome)
        Log.i(TAG, "detected: type=$type amount=$amount from=${sbn.packageName}")
        PaymentEvents.post(amount, sbn.packageName, content, type, sbn.postTime)
    }

    /**
     * 收支方向判定。收入词与支出词同时命中时以支出为准（保持原有行为），
     * 只命中歧义词「转账」时默认按流出处理。
     */
    private fun resolveType(isExpense: Boolean, isIncome: Boolean): String = when {
        isIncome && !isExpense -> TYPE_INCOME
        isExpense -> TYPE_EXPENSE
        isIncome -> TYPE_INCOME
        else -> TYPE_EXPENSE
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
