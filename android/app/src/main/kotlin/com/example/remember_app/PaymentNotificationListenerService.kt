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
        // 任何一条通知都证明服务还活着，先记一笔存活时间。
        // 这一条是「绑定到底掉没掉」最直接的判据：
        // 收到过 = 绑定是活的（问题多半在文案识别），没收到过 = 绑定真的僵死了。
        ListenerDiagnostics.recordEvent(applicationContext)

        if (sbn.packageName == packageName) return

        val content = extractContent(sbn.notification.extras)
        if (content.isBlank()) return

        // 关键词匹配与金额提取都交给纯 Kotlin 的 PaymentParser，
        // 那边有 JVM 单元测试覆盖，改动不会只靠真机才发现问题。
        val diagnosis = PaymentParser.diagnose(content)
        val parsed = diagnosis.result
        if (parsed == null) {
            // 不是支付通知（或者缺少金额/方向），直接忽略。
            // 但把原文和原因记下来，用户在 App 里能直接看到「为什么没记」，
            // 并且能一键补记——原文里能读出金额时，方向由用户自己选。
            Log.d(TAG, "ignored: $content")
            if (looksFinancial(content)) {
                ListenerDiagnostics.recordNotification(
                    applicationContext,
                    sbn.packageName,
                    extractTitle(sbn.notification.extras),
                    extractBody(sbn.notification.extras),
                    false,
                    diagnosis.reason,
                    PaymentParser.findAnyAmount(content)
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
                "已识别：${parsed.type} ${parsed.amount}",
                parsed.amount
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
     * 判定逻辑放在 PaymentParser 里（纯 Kotlin，有单测覆盖），
     * 条件刻意放宽，见 [PaymentParser.looksFinancial]。
     */
    private fun looksFinancial(content: String): Boolean =
        PaymentParser.looksFinancial(content)

    override fun onListenerConnected() {
        super.onListenerConnected()
        ListenerDiagnostics.recordConnected(applicationContext)
        // 连上了就（重新）排上保活闹钟。
        // 进程被杀、用户强制停止、系统重启之后，闹钟才是我们能回来的唯一途径。
        ListenerKeepAlive.schedule(applicationContext)
        // 常驻前台服务：进程优先级更高，国产 ROM 的清理后台一般会跳过它。
        // 这时候系统正绑着我们，是允许启动前台服务的场景之一。
        ListenerForegroundService.ensureRunning(applicationContext)
        // Job 跨重启保留，闹钟会被系统清掉，两者都要排。
        ListenerWatchdogJob.schedule(applicationContext)
        Log.i(TAG, "通知监听已连接")
    }

    override fun onListenerDisconnected() {
        ListenerDiagnostics.recordDisconnected(applicationContext)
        super.onListenerDisconnected()
        Log.w(TAG, "通知监听已断开")
        // 断开了立刻请求重新绑定——这是最省事、最有效的一步。
        // 系统在部分设备上解绑之后不会自己绑回来，不主动请求就再也回不去了。
        ListenerKeepAlive.rebind(applicationContext)
    }

    override fun onDestroy() {
        // 服务被销毁说明进程要没了（或系统要收它），留个痕迹。
        ListenerDiagnostics.recordDisconnected(applicationContext)
        // 顺手记一下进程是怎么没的：低内存回收是我们能自己救回来的，
        // 「强行停止」则救不回来，得告诉用户。
        ProcessExit.lastExit(applicationContext)?.let { record ->
            ListenerDiagnostics.recordKill(applicationContext, record.timestamp, record.describe())
        }
        Log.w(TAG, "通知监听服务被销毁")
        super.onDestroy()
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
