package com.example.remember_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class PaymentNotificationListenerService : NotificationListenerService() {

    private val expenseKeywords = listOf("支付成功","付款成功","消费","支出","扣款","购买","下单","还款","充值")
    private val incomeKeywords = listOf("收款","到账","转入","红包")

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val content = "$title $text"

        val isExpense = expenseKeywords.any { content.contains(it) }
        val isIncome = incomeKeywords.any { content.contains(it) }
        if (!isExpense && !isIncome) return

        val amount = extractAmount(content) ?: return
        val type = if (isIncome && !isExpense) TYPE_INCOME else TYPE_EXPENSE
        Log.i(TAG, "detected: type=$type amount=$amount from=${sbn.packageName}")
        PaymentEvents.post(amount, sbn.packageName, content, type)
    }

    private fun extractAmount(content: String): Double? {
        val symbol = Regex("""(?:¥|￥|RMB)\s*(\d{1,7}(?:\.\d{1,2})?)|(\d{1,7}(?:\.\d{1,2})?)\s*元""")
        symbol.find(content)?.let {
            val raw = it.groupValues[1].ifEmpty { it.groupValues[2] }
            if (raw.isNotBlank()) return raw.replace(",", "").toDoubleOrNull()
        }
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