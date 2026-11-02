package com.example.remember_app

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 进程内总线：服务 -> Flutter。
 *
 * 关键点：通知监听服务由系统绑定维持。App 被划掉 / 被系统回收后，进程会因为服务
 * 被重新拉起，此时 MainActivity 不会重建，Dart 侧也没有订阅，
 * [listener] 为 null。如果直接丢弃事件，用户在没打开 App 的情况下收到的支付通知
 * 全部丢失——而这恰恰是这个功能最主要的使用场景。
 *
 * 因此 listener 为空时把事件落盘缓存，等 Dart 订阅后再补发。
 */
object PaymentEvents {
    private const val TAG = "PaymentEvents"
    private const val PREFS = "payment_events"
    private const val KEY_PENDING = "pending"
    private const val MAX_PENDING = 200

    @Volatile
    private var appContext: Context? = null

    var listener: ((Double, String, String, String, Long) -> Unit)? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /**
     * @param timestamp 事件发生时间（通知的 postTime，毫秒）。
     *                   缓存补发时用它还原原始日期，否则隔天补记会记成补记当天的日期。
     */
    fun post(amount: Double, sourceApp: String, content: String, type: String, timestamp: Long) {
        val l = listener
        if (l != null) {
            l(amount, sourceApp, content, type, timestamp)
        } else {
            enqueue(amount, sourceApp, content, type, timestamp)
        }
    }

    private fun prefs(): SharedPreferences? =
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readPending(p: SharedPreferences): JSONArray {
        val raw = p.getString(KEY_PENDING, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            Log.w(TAG, "pending 缓存损坏，已重置", e)
            JSONArray()
        }
    }

    private fun enqueue(amount: Double, sourceApp: String, content: String, type: String, timestamp: Long) {
        val p = prefs() ?: return
        val arr = readPending(p)
        arr.put(
            JSONObject().apply {
                put("amount", amount)
                put("sourceApp", sourceApp)
                put("content", content)
                put("type", type)
                put("timestamp", timestamp)
            }
        )
        // 防止无限增长：超出上限时丢掉最旧的。
        while (arr.length() > MAX_PENDING) arr.remove(0)
        // 用 commit 而不是 apply：这条通知是「用户已经付了钱」的凭据，
        // 而 App 可能随时被系统或清理助手杀掉——apply 的异步写盘
        // 在进程被杀时来不及落盘，这笔账就凭空没了。
        // 崩溃记录（CrashRecorder）也是同样的理由用 commit。
        p.edit().putString(KEY_PENDING, arr.toString()).commit()
        Log.i(TAG, "无 Flutter 监听，事件已缓存，积压 ${arr.length()} 条")
    }

    /**
     * Dart 侧订阅后调用，补发 App 未运行期间积压的事件。
     *
     * ## 交付成功才算数
     *
     * 旧实现是「先清空缓存，再逐条回调」：
     * 进程正好在回调途中被杀的话，这批事件**既没补发出去、也没留在缓存里**，
     * 直接消失了。
     *
     * 现在改成：逐条交付，**交付成功的才从缓存里移除**，
     * 交付失败的（回调抛异常）留在缓存里下次再试。
     * 这样「进程被杀」最多让这一批晚点补上，不会凭空消失。
     */
    fun flushPending(onEvent: (Double, String, String, String, Long) -> Unit) {
        val p = prefs() ?: return
        val arr = readPending(p)
        if (arr.length() == 0) return

        val remaining = JSONArray()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            var delivered = false
            try {
                onEvent(
                    o.optDouble("amount", 0.0),
                    o.optString("sourceApp", ""),
                    o.optString("content", ""),
                    o.optString("type", "expense"),
                    o.optLong("timestamp", System.currentTimeMillis())
                )
                delivered = true
            } catch (e: Throwable) {
                Log.w(TAG, "补发事件失败，留在缓存里下次再试: $e")
            }
            if (!delivered) {
                remaining.put(o)
            }
        }

        if (remaining.length() > 0) {
            p.edit().putString(KEY_PENDING, remaining.toString()).commit()
        } else {
            p.edit().remove(KEY_PENDING).commit()
        }
        Log.i(TAG, "补发缓存事件 ${arr.length() - remaining.length()} 条")
    }
}
