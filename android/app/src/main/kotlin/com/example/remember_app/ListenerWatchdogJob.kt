package com.example.remember_app

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.util.Log

/**
 * 周期性的看门狗任务。
 *
 * ## 为什么闹钟之外还要 Job
 *
 * 闹钟和 Job 都能把进程拉起来，但抗清理的能力不一样：
 *
 * - **闹钟**在国产 ROM 的「清理后台」「省电策略」下经常被一起清掉，
 *   而且 Doze 下 `setAndAllowWhileIdle` 会被推迟；
 * - **JobScheduler 的任务**由系统托管，进程被杀后系统会重新调度它，
 *   还能用 `setPersisted` 跨设备重启保留。
 *
 * 两条腿一起走，任一条被掐掉另一条还能把进程拉回来。
 * （App 被「强行停止」时两者都会被清掉——那是平台限制，无解。）
 */
class ListenerWatchdogJob : JobService() {

    override fun onStartJob(params: JobParameters?): Boolean {
        // onStartJob 跑在主线程，重活丢到线程池去。
        val appContext = applicationContext
        Thread({
            try {
                ListenerWatchdog.checkAndRepair(appContext, "job")
            } catch (e: Throwable) {
                Log.w(TAG, "看门狗 Job 出错: $e")
            }
        }, "listener-watchdog").start()
        // false：这次工作干完就算结束，不需要系统立刻重排。
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        // 被中途掐掉了，下次重新排上。
        return true
    }

    companion object {
        private const val TAG = "WatchdogJob"

        private const val JOB_ID = 4102

        /** 检查间隔：30 分钟。 */
        const val INTERVAL_MS = 30L * 60 * 1000

        /**
         * 排上周期任务。已存在时会替换成新的。
         */
        fun schedule(context: Context) {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE)
                as? JobScheduler ?: return
            try {
                val job = JobInfo.Builder(
                    JOB_ID,
                    ComponentName(context.applicationContext, ListenerWatchdogJob::class.java)
                )
                    .setPersisted(true)
                    .setPeriodic(INTERVAL_MS)
                    .build()
                scheduler.schedule(job)
            } catch (e: Throwable) {
                Log.w(TAG, "排看门狗任务失败: $e")
            }
        }

        /** 取消周期任务。 */
        fun cancel(context: Context) {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE)
                as? JobScheduler ?: return
            try {
                scheduler.cancel(JOB_ID)
            } catch (e: Throwable) {
                Log.w(TAG, "取消看门狗任务失败: $e")
            }
        }
    }
}
