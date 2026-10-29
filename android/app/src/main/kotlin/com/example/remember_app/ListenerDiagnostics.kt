package com.example.remember_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * 通知监听诊断信息。
 *
 * 存在的理由：用户反馈「有通知但没记账」时，光看「通知监听已开启」是查不出问题的——
 * 那个状态只说明系统设置里勾上了，不代表监听服务真的活着，
 * 也不代表通知文案被成功识别。这里把服务连接状态和最近收到的
 * 「疑似支付类」通知记下来，让 App 自己能回答三个问题：
 * 到底收到没收到 / 收到的是啥 / 为什么没记。
 */
object ListenerDiagnostics {
    private const val PREFS = "listener_diagnostics"
    private const val KEY_CONNECTED_AT = "connectedAt"
    private const val KEY_DISCONNECTED_AT = "disconnectedAt"
    private const val KEY_NOTIFS = "notifs"
    private const val KEY_LAST_REBIND_AT = "lastRebindAt"
    private const val KEY_REBIND_COUNT = "rebindCount"
    private const val KEY_LAST_REBIND_OK = "lastRebindOk"
    private const val KEY_KEEP_ALIVE_ARMED = "keepAliveArmed"
    private const val KEY_LAST_EVENT_AT = "lastEventAt"
    private const val KEY_RECONNECT_AT = "lastReconnectAt"
    private const val KEY_RECONNECT_OK = "lastReconnectOk"
    private const val KEY_RECONNECT_STAGE = "lastReconnectStage"
    private const val KEY_RECONNECT_MESSAGE = "lastReconnectMessage"
    private const val KEY_BACKGROUND_MONITORING = "backgroundMonitoring"
    private const val KEY_LAST_ESCALATE_AT = "lastEscalateAt"
    private const val KEY_LAST_ESCALATE_OK = "lastEscalateOk"
    private const val KEY_AUTO_REPAIR_AT = "autoRepairAt"
    private const val KEY_AUTO_REPAIR_RESULT = "autoRepairResult"
    private const val KEY_AUTO_REPAIR_MESSAGE = "autoRepairMessage"
    private const val KEY_LAST_KILL_AT = "lastKillAt"
    private const val KEY_LAST_KILL_REASON = "lastKillReason"

    /**
     * 「收到过通知」这个存活信号的写入间隔：1 分钟。
     *
     * 聊天消息可能一分钟好几条，每条都写盘没必要这么勤；
     * 而「最近还活着」的判断窗口是几十分钟，1 分钟的精度完全够用。
     */
    private const val EVENT_WRITE_INTERVAL_MS = 60_000L

    /**
     * 保留多少条历史通知。
     *
     * 存 50 条而不是 20 条：用户微信里聊几句天就可能把真正的支付通知顶出缓冲区，
     * 那样「最近收到通知」里就找不到要排查的那条了。体积只有几 KB。
     */
    private const val MAX_NOTIFS = 50

    /** 监听服务连上系统时调用。 */
    fun recordConnected(context: Context) {
        prefs(context)?.edit()?.putLong(KEY_CONNECTED_AT, System.currentTimeMillis())?.apply()
    }

    /** 监听服务与系统断开时调用。 */
    fun recordDisconnected(context: Context) {
        prefs(context)?.edit()?.putLong(KEY_DISCONNECTED_AT, System.currentTimeMillis())?.apply()
    }

    /**
     * 记录「刚刚收到了一条通知」。
     *
     * 这是判断监听服务死活最可靠的信号。
     *
     * [recordNotification] 那套只留「疑似支付类」的通知，
     * 用户几天不付款时它就一直停在旧时间上，
     * 分不清「没收到支付通知」和「服务已经死了」这两种完全不同的情况。
     * 这里记的是**任何**通知（聊天消息也算）——
     * 只要还在收，就说明监听服务是活的，问题多半出在文案识别上；
     * 连这条时间都停了，才是绑定真的掉了。
     */
    fun recordEvent(context: Context) {
        val p = prefs(context) ?: return
        val now = System.currentTimeMillis()
        val last = p.getLong(KEY_LAST_EVENT_AT, 0L)
        if (now - last < EVENT_WRITE_INTERVAL_MS) return
        p.edit().putLong(KEY_LAST_EVENT_AT, now).apply()
    }

    /**
     * 记录一次「请求重新绑定监听服务」。
     *
     * 用户报「一开始有效、后来就收不到了」时，
     * 这条记录能回答：App 有没有在尝试自救、试了几次、有没有成功。
     */
    fun recordRebind(context: Context, ok: Boolean) {
        val p = prefs(context) ?: return
        val count = p.getInt(KEY_REBIND_COUNT, 0) + 1
        p.edit()
            .putLong(KEY_LAST_REBIND_AT, System.currentTimeMillis())
            .putInt(KEY_REBIND_COUNT, count)
            .putBoolean(KEY_LAST_REBIND_OK, ok)
            .apply()
    }

    /** 记录保活闹钟是否已经排上。 */
    fun recordKeepAlive(context: Context, armed: Boolean) {
        prefs(context)?.edit()?.putBoolean(KEY_KEEP_ALIVE_ARMED, armed)?.apply()
    }

    /**
     * 记录一次「手动重连监听服务」的结果。
     *
     * 把结果留在本机而不是只弹一下提示框：
     * 用户下次打开 App 时还能看到「上次重连是什么时候、结果是什么」，
     * 不用凭记忆猜。
     */
    fun recordReconnect(context: Context, ok: Boolean, stage: String, message: String) {
        prefs(context)?.edit()
            ?.putLong(KEY_RECONNECT_AT, System.currentTimeMillis())
            ?.putBoolean(KEY_RECONNECT_OK, ok)
            ?.putString(KEY_RECONNECT_STAGE, stage)
            ?.putString(KEY_RECONNECT_MESSAGE, message)
            ?.apply()
    }

    /**
     * 记录一次「自动修复」的尝试。
     *
     * 自动保活不是黑盒：用户反馈「监听又没了」时，得能回答
     * 「App 自己试过没有、试了几次、哪一步没成」。
     *
     * @param result alive / rebind / escalated / escalate_failed / unauthorized
     */
    fun recordAutoRepair(context: Context, result: String, message: String) {
        prefs(context)?.edit()
            ?.putLong(KEY_AUTO_REPAIR_AT, System.currentTimeMillis())
            ?.putString(KEY_AUTO_REPAIR_RESULT, result)
            ?.putString(KEY_AUTO_REPAIR_MESSAGE, message)
            ?.apply()
    }

    /**
     * 记录一次「重置监听组件」这种重手段。
     *
     * 单独记一条，是因为它有副作用（系统可能临时拉黑这个监听器），
     * 需要能查「上一次自动这么做是什么时候、成没成功」。
     */
    fun recordEscalation(context: Context, ok: Boolean) {
        prefs(context)?.edit()
            ?.putLong(KEY_LAST_ESCALATE_AT, System.currentTimeMillis())
            ?.putBoolean(KEY_LAST_ESCALATE_OK, ok)
            ?.apply()
    }

    /** 记录进程最后一次是怎么没的。 */
    fun recordKill(context: Context, timestamp: Long, reason: String) {
        prefs(context)?.edit()
            ?.putLong(KEY_LAST_KILL_AT, timestamp)
            ?.putString(KEY_LAST_KILL_REASON, reason)
            ?.apply()
    }

    /**
     * 用户要不要「后台常驻监听」。
     *
     * 默认开启——这个 App 的核心价值就是后台自动记账，
     * 关掉常驻服务就等于把它关掉了。留这个开关是因为
     * 常驻通知会占一条通知栏，有人不喜欢。
     */
    fun isBackgroundMonitoringEnabled(context: Context): Boolean =
        prefs(context)?.getBoolean(KEY_BACKGROUND_MONITORING, true) ?: true

    /** 设置「后台常驻监听」开关。 */
    fun setBackgroundMonitoring(context: Context, enabled: Boolean) {
        prefs(context)?.edit()
            ?.putBoolean(KEY_BACKGROUND_MONITORING, enabled)
            ?.apply()
    }

    /**
     * 记下一条通知。
     *
     * @param recognized 是否被识别成支付通知；false 时 [reason] 说明为什么没记。
     * @param amount 正文里能读到的金额（可能为 null）。
     * @param recorded 是否已经被用户手动补记过。
     */
    fun recordNotification(
        context: Context,
        packageName: String,
        title: String,
        text: String,
        recognized: Boolean,
        reason: String,
        amount: Double? = null,
        recorded: Boolean = false
    ) {
        val p = prefs(context) ?: return
        val arr = readNotifs(p)
        arr.put(
            JSONObject().apply {
                put("packageName", packageName)
                put("title", title)
                put("text", text)
                put("recognized", recognized)
                put("reason", reason)
                put("timestamp", System.currentTimeMillis())
                put("amount", amount ?: JSONObject.NULL)
                put("recorded", recorded)
            }
        )
        while (arr.length() > MAX_NOTIFS) arr.remove(0)
        p.edit().putString(KEY_NOTIFS, arr.toString()).apply()
    }

    /**
     * 标记某条通知已被用户手动补记。
     *
     * 诊断列表里那条通知还在，但按钮会变成「已补记」，避免重复点出两条账单。
     */
    fun markRecorded(context: Context, timestamp: Long): Boolean {
        val p = prefs(context) ?: return false
        val arr = readNotifs(p)
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (o.optLong("timestamp", 0L) == timestamp) {
                o.put("recorded", true)
                p.edit().putString(KEY_NOTIFS, arr.toString()).apply()
                return true
            }
        }
        return false
    }

    /** 取诊断快照，供 MethodChannel 返回给 Dart。 */
    fun snapshot(context: Context, listenerEnabled: Boolean): Map<String, Any?> {
        val p = prefs(context)
        val arr = p?.let { readNotifs(it) } ?: JSONArray()

        val notifs = ArrayList<Map<String, Any?>>()
        // 新的排在前面。
        for (i in arr.length() - 1 downTo 0) {
            val o = arr.optJSONObject(i) ?: continue
            val amount = if (o.isNull("amount")) null else o.optDouble("amount", 0.0)
            notifs.add(
                mapOf(
                    "packageName" to o.optString("packageName", ""),
                    "title" to o.optString("title", ""),
                    "text" to o.optString("text", ""),
                    "recognized" to o.optBoolean("recognized", false),
                    "reason" to o.optString("reason", ""),
                    "timestamp" to o.optLong("timestamp", 0L),
                    "amount" to amount,
                    "recorded" to o.optBoolean("recorded", false)
                )
            )
        }

        val lastAt = if (arr.length() > 0) arr.optJSONObject(arr.length() - 1)?.optLong("timestamp", 0L) ?: 0L else 0L

        return mapOf(
            "listenerEnabled" to listenerEnabled,
            "serviceConnectedAt" to (p?.getLong(KEY_CONNECTED_AT, 0L) ?: 0L),
            "serviceDisconnectedAt" to (p?.getLong(KEY_DISCONNECTED_AT, 0L) ?: 0L),
            "lastNotificationAt" to lastAt,
            "lastRebindAt" to (p?.getLong(KEY_LAST_REBIND_AT, 0L) ?: 0L),
            "rebindCount" to (p?.getInt(KEY_REBIND_COUNT, 0) ?: 0),
            "lastRebindOk" to (p?.getBoolean(KEY_LAST_REBIND_OK, false) ?: false),
            "keepAliveArmed" to (p?.getBoolean(KEY_KEEP_ALIVE_ARMED, false) ?: false),
            "lastEventAt" to (p?.getLong(KEY_LAST_EVENT_AT, 0L) ?: 0L),
            "lastReconnectAt" to (p?.getLong(KEY_RECONNECT_AT, 0L) ?: 0L),
            "lastReconnectOk" to (p?.getBoolean(KEY_RECONNECT_OK, false) ?: false),
            "lastReconnectStage" to (p?.getString(KEY_RECONNECT_STAGE, "") ?: ""),
            "lastReconnectMessage" to (p?.getString(KEY_RECONNECT_MESSAGE, "") ?: ""),
            "backgroundMonitoring" to (p?.getBoolean(KEY_BACKGROUND_MONITORING, true) ?: true),
            "foregroundServiceRunning" to ListenerForegroundService.isRunning(context),
            "lastEscalateAt" to (p?.getLong(KEY_LAST_ESCALATE_AT, 0L) ?: 0L),
            "lastEscalateOk" to (p?.getBoolean(KEY_LAST_ESCALATE_OK, false) ?: false),
            "autoRepairAt" to (p?.getLong(KEY_AUTO_REPAIR_AT, 0L) ?: 0L),
            "autoRepairResult" to (p?.getString(KEY_AUTO_REPAIR_RESULT, "") ?: ""),
            "autoRepairMessage" to (p?.getString(KEY_AUTO_REPAIR_MESSAGE, "") ?: ""),
            "lastKillAt" to (p?.getLong(KEY_LAST_KILL_AT, 0L) ?: 0L),
            "lastKillReason" to (p?.getString(KEY_LAST_KILL_REASON, "") ?: ""),
            "recentNotifications" to notifs
        )
    }

    private fun prefs(context: Context): SharedPreferences? =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readNotifs(p: SharedPreferences): JSONArray {
        val raw = p.getString(KEY_NOTIFS, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            JSONArray()
        }
    }
}
