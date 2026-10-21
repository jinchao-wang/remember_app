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
    private const val MAX_NOTIFS = 20

    /** 监听服务连上系统时调用。 */
    fun recordConnected(context: Context) {
        prefs(context)?.edit()?.putLong(KEY_CONNECTED_AT, System.currentTimeMillis())?.apply()
    }

    /** 监听服务与系统断开时调用。 */
    fun recordDisconnected(context: Context) {
        prefs(context)?.edit()?.putLong(KEY_DISCONNECTED_AT, System.currentTimeMillis())?.apply()
    }

    /**
     * 记下一条通知。
     *
     * @param recognized 是否被识别成支付通知；false 时 [reason] 说明为什么没记。
     */
    fun recordNotification(
        context: Context,
        packageName: String,
        title: String,
        text: String,
        recognized: Boolean,
        reason: String
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
            }
        )
        while (arr.length() > MAX_NOTIFS) arr.remove(0)
        p.edit().putString(KEY_NOTIFS, arr.toString()).apply()
    }

    /** 取诊断快照，供 MethodChannel 返回给 Dart。 */
    fun snapshot(context: Context, listenerEnabled: Boolean): Map<String, Any?> {
        val p = prefs(context)
        val arr = p?.let { readNotifs(it) } ?: JSONArray()

        val notifs = ArrayList<Map<String, Any?>>()
        // 新的排在前面。
        for (i in arr.length() - 1 downTo 0) {
            val o = arr.optJSONObject(i) ?: continue
            notifs.add(
                mapOf(
                    "packageName" to o.optString("packageName", ""),
                    "title" to o.optString("title", ""),
                    "text" to o.optString("text", ""),
                    "recognized" to o.optBoolean("recognized", false),
                    "reason" to o.optString("reason", ""),
                    "timestamp" to o.optLong("timestamp", 0L)
                )
            )
        }

        val lastAt = if (arr.length() > 0) arr.optJSONObject(arr.length() - 1)?.optLong("timestamp", 0L) ?: 0L else 0L

        return mapOf(
            "listenerEnabled" to listenerEnabled,
            "serviceConnectedAt" to (p?.getLong(KEY_CONNECTED_AT, 0L) ?: 0L),
            "serviceDisconnectedAt" to (p?.getLong(KEY_DISCONNECTED_AT, 0L) ?: 0L),
            "lastNotificationAt" to lastAt,
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
