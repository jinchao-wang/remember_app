package com.example.remember_app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log

/**
 * 进程退出历史。
 *
 * ## 为什么要查这个
 *
 * 用户报「时间久了监听就没了」，根因其实是**进程没了**，而不是解析出了问题。
 * 而进程没了有好几种完全不同的死法，处理方式也完全不同：
 *
 * | 退出原因 | 含义 | 能自己救回来吗 |
 * | --- | --- | --- |
 * | 低内存回收 | 系统内存不够，把进程杀了 | 能。系统随时会重新绑定，前台服务也会被重启 |
 * | 用户划掉最近任务 | 用户把 App 从最近任务里删了 | 能。闹钟/Job 会把进程拉回来 |
 * | 设置里「强行停止」 | 系统把 App 标记为 stopped | **不能**。Android 规定此时不跑任何组件，直到用户再打开一次 |
 *
 * 最后一种是**平台级的硬限制**：被强行停止后，闹钟、后台服务、Job 全部停用，
 * 连通知监听服务也不会被系统绑定回来。任何 App 都绕不过去——
 * 唯一的办法是让用户手动打开一次。
 *
 * 所以这里做两件事：
 * 1. 进程被回收时，尽量自己拉回来（前台服务 + 闹钟 + Job 三条腿）；
 * 2. 遇到「强行停止」这种救不回来的，如实告诉用户，别让他干等。
 */
object ProcessExit {

    private const val TAG = "ProcessExit"

    /** 一次退出记录。 */
    data class ExitRecord(
        /** 进程结束的时间戳（毫秒）。 */
        val timestamp: Long,
        /** ApplicationExitInfo.REASON_* 原始值。 */
        val reason: Int,
        /** 用户在系统设置里点了「强行停止」。 */
        val userForceStopped: Boolean,
        /** 用户把 App 从最近任务里划掉了。 */
        val userSwipedAway: Boolean,
        /** 系统内存不足回收。 */
        val lowMemory: Boolean
    ) {
        /**
         * 给用户看的一句话。
         *
         * ## 这里只能说到什么程度
         *
         * Android 14 上，「从最近任务划掉」和「设置里点强行停止」记的都是
         * `REASON_USER_REQUESTED`，只有内部一个 subreason 不同，
         * 而那个 subreason **不是公开 API**（`javap` 查过，android.jar 里没有
         * `getSubreason`）。
         *
         * 所以这里不硬掰「到底是不是被强停了」——
         * 分不清就说分不清，把准确的那部分说准：
         * 是崩溃、是内存不足、是 App 更新、还是用户手动结束的。
         *
         * 至于「现在还能不能监听」，那由「监听有没有重新连上」来回答，
         * 那个是测得准的，见诊断里的 `lastKillAt` 与 `serviceConnectedAt` 对比。
         */
        fun describe(): String = when {
            reason == ApplicationExitInfo.REASON_CRASH ||
                reason == ApplicationExitInfo.REASON_CRASH_NATIVE -> "崩溃退出"
            reason == ApplicationExitInfo.REASON_ANR -> "无响应，被系统结束"
            lowMemory -> "因内存不足被系统回收"
            reason == ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "App 更新后重启"
            userForceStopped -> "被强行停止"
            userSwipedAway -> "被用户手动结束（划掉或清理后台）"
            else -> "被系统结束"
        }
    }

    /**
     * 查最近一次本 App 进程的退出记录。
     *
     * 只有 Android 11（API 30）以上才有这个能力，
     * 更早的版本返回 null（那时拿不到退出原因，只能靠别的信号判断）。
     */
    fun lastExit(context: Context): ExitRecord? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: return null
            val reasons: List<ApplicationExitInfo> =
                am.getHistoricalProcessExitReasons(context.packageName, 0, 5)
            val latest = reasons
                .filter { it.timestamp > 0 }
                .maxByOrNull { it.timestamp }
                ?: return null
            ExitRecord(
                timestamp = latest.timestamp,
                reason = latest.reason,
                userForceStopped = latest.reason == ApplicationExitInfo.REASON_USER_STOPPED,
                userSwipedAway = latest.reason == ApplicationExitInfo.REASON_USER_REQUESTED,
                lowMemory = latest.reason == ApplicationExitInfo.REASON_LOW_MEMORY
            )
        } catch (e: Throwable) {
            Log.w(TAG, "读取进程退出历史失败: $e")
            null
        }
    }

    /**
     * 最近一次「不是用户主动强停」的进程结束时间。
     *
     * ## 认哪些死法
     *
     * - **低内存回收**：系统内存不够，把进程杀了。
     * - **用户划掉最近任务 / 清理助手杀后台**：用户（或 ROM 的清理助手）
     *   把 App 从后台干掉了。
     *
     * 这两种都要算，因为**它们都只杀进程，不解绑、不禁用**：
     * 系统理论上应该把通知监听服务重新绑回来，绑不回来才是故障。
     * 「用户划掉之后监听就再也不生效了」正是这么来的。
     *
     * 至于「用户在系统设置里点了强行停止」——那是平台级的硬限制，
     * 被强停后系统不跑本 App 的任何组件，闹钟和 Job 也被清掉了，
     * 看门狗根本轮不到跑；用户重新打开 App 时系统会重新绑定。
     * 所以它不该被当成故障证据。
     *
     * Android 14 上「划掉」和「强停」都记成 `REASON_USER_REQUESTED`，
     * 内部那个能区分二者的 subreason 不是公开 API，拿不到。
     * 但这不会造成误判：被强停时闹钟和 Job 都被清掉了，
     * 看门狗压根不会运行；等用户重新打开 App，系统会重新绑定。
     */
    fun lastUnexpectedKillAt(context: Context): Long {
        val record = lastExit(context) ?: return 0L
        return if (record.lowMemory || record.userSwipedAway) record.timestamp else 0L
    }
}
