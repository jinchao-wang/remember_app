package com.example.remember_app

import android.content.Context
import android.util.Log

/**
 * 崩溃记录器。
 *
 * ## 为什么需要它
 *
 * 用户只会说「App 打不开了」——闪退、白屏、卡在启动页，看上去一模一样，
 * 光看现象查不出原因。这里把崩溃时的异常原样记下来，下次打开 App 时
 * 在首页和「设置 → 诊断详情」里显示给用户看。
 *
 * ## 为什么要放在独立文件里
 *
 * 崩溃可能发生在**任何**进程阶段，不只是 Activity 存在的时候：
 *
 * - 系统为绑定通知监听服务而拉起进程（此时没有 Activity）；
 * - 前台服务在后台被拉起；
 * - Flutter 引擎初始化阶段。
 *
 * 所以每个可能最早运行的组件（Activity / 监听服务 / 前台服务）都调一次
 * [install]。装过就不会重复装。
 */
object CrashRecorder {

    private const val TAG = "CrashRecorder"

    @Volatile
    private var installed = false

    /**
     * 装上全局崩溃处理器。
     *
     * 幂等：重复调用只生效一次。
     */
    @Synchronized
    fun install(context: Context) {
        if (installed) return
        installed = true
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val message = describe(throwable)
                Log.e(TAG, "App 崩溃: $message", throwable)
                ListenerDiagnostics.recordCrash(appContext, message)
            } catch (e: Throwable) {
                // 记崩溃失败也不能再崩一次。
            }
            // 交给系统原来的处理流程（弹崩溃框、结束进程）。
            if (previous != null) {
                previous.uncaughtException(thread, throwable)
            } else {
                // 没有默认处理器的话系统不会来收尾，
                // 进程会半死不活地僵在原地——那正是「App 打不开」最难缠的死法。
                // 这里自己收干净，至少让用户下次能重新打开。
                android.os.Process.killProcess(android.os.Process.myPid())
                kotlin.system.exitProcess(10)
            }
        }
    }

    /**
     * 把异常压成一行能存进 SharedPreferences 的文字。
     *
     * 只带最上面几帧：完整堆栈可能几百行，塞不下，
     * 而且用户看得懂的是「在哪儿炸的」。
     */
    private fun describe(throwable: Throwable): String {
        val sb = StringBuilder()
        sb.append(throwable.javaClass.simpleName)
        throwable.message?.let { sb.append(": ").append(it) }
        throwable.stackTrace.take(6).forEach { frame ->
            sb.append("\n  at ").append(frame)
        }
        return sb.toString()
    }
}
