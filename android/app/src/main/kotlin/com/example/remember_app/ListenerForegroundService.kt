package com.example.remember_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 后台常驻前台服务。
 *
 * ## 为什么需要它
 *
 * 通知监听服务是**由系统绑定**的，进程没了绑定也就没了。
 * 之前 App 只有一条腿：闹钟。闹钟把进程拉起来后请求一次重新绑定，
 * 但
 * - 闹钟在国产 ROM 的「一键清理」下经常连闹钟本身都被清掉；
 * - `setAndAllowWhileIdle` 在 Doze 下会被推迟；
 * - 就算进程起来了，监听服务也未必会被系统重新绑上。
 *
 * 有一个**前台服务**在跑，情况完全不同：
 *
 * 1. **进程优先级高**，不会被系统的低内存回收第一个盯上；
 * 2. **国产 ROM 的「清理后台」会跳过有前台服务的 App**——
 *    用户看到的通知栏里有一条常驻通知，清助手一般不敢动它；
 * 3. **`START_STICKY`**，进程被系统回收后，系统会把它重新拉起来；
 * 4. 用户自己看得见「App 还活着」，不用猜。
 *
 * 这几条正是用户说的「把程序关了后台依旧能监听」里能做到的部分。
 *
 * ## 做不到的部分
 *
 * 用户在系统设置里点「强行停止」之后，Android 会把 App 标记为 stopped，
 * 此时**不跑任何组件**：闹钟、后台服务、Job 全停，通知监听也不会被绑定。
 * 这是平台级的硬限制，任何 App 都绕不过——必须让用户重新打开一次。
 * 这件事由 [ProcessExit] 检测出来，在 App 里如实告诉用户。
 */
class ListenerForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // 崩溃记录器：后台被杀时进程里可能根本没有 Activity，
        // 在这里装一次才能抓到那些崩溃。
        CrashRecorder.install(applicationContext)
        // 这个服务和 App 跑在**同一个进程**里。
        // 它里面任何未捕获的异常都会把整个 App 一起带走——
        // 表现就是「点开图标闪一下就没了」，用户完全看不懂。
        //
        // 所以这里的每个回调都自己兜住异常：常驻服务是锦上添花，
        // 绝不能因为它把 App 搞崩。
        try {
            createChannel()
        } catch (e: Throwable) {
            Log.w(TAG, "创建通知渠道失败: $e")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 整个方法体兜住异常：这里是系统回调，抛出去就是进程猝死。
        try {
            // 进前台：必须尽早调用 startForeground。
            //
            // 注意这里**没有**「5 秒内不调用就会被系统判超时」的压力了——
            // 那是因为以前用的是 startForegroundService()，系统会挂看门狗。
            // 现在改用普通 startService()（理由见 [ensureRunning]），
            // 系统不挂看门狗，进不去前台只是少一条常驻通知，不会猝死。
            if (!startForegroundCompat()) {
                // 进不去前台就把自己停掉：留着也是个会被系统回收的后台服务，
                // 反而像是「App 还活着」却没干活。
                //
                // 什么情况下会进不去前台？Android 8+ 限制在后台启动服务：
                // 闹钟/Job 把进程拉起来时，服务可能根本不被允许启动。
                // 这种情况下放弃常驻服务即可——闹钟和 Job 两条腿还在，
                // 用户下次打开 App 时会再试。
                Log.w(TAG, "无法进入前台，停掉常驻服务")
                try {
                    stopSelf()
                } catch (e: Throwable) {
                    Log.w(TAG, "停止服务失败: $e")
                }
                return START_NOT_STICKY
            }
            // START_STICKY：进程被系统回收之后，系统会重新把它拉起来。
            // 这正是「退到后台 / 被清理之后还能继续监听」的关键。
            return START_STICKY
        } catch (e: Throwable) {
            // 兜底：这里抛出去系统会当进程崩溃处理，App 直接闪退。
            Log.w(TAG, "常驻服务启动失败，已停掉: $e")
            try {
                stopSelf()
            } catch (t: Throwable) {
                Log.w(TAG, "停止服务失败: $t")
            }
            return START_NOT_STICKY
        }
    }

    /**
     * 进入前台。
     *
     * @return 是否成功。失败时服务会退化成普通后台服务（不会有通知、
     *   优先级也低），但**不会**让进程猝死。
     */
    private fun startForegroundCompat(): Boolean {
        // buildNotification 也要放进 try 里：
        // 它会去拿 App 的启动 Intent（getLaunchIntentForPackage），
        // 万一拿不到，PendingIntent 构造会抛异常——
        // 那时候如果没接住，异常会一路冒到 onStartCommand 外面，
        // **把整个 App 进程带崩**。
        return try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14 起必须显式带上类型，否则会抛
                // MissingForegroundServiceTypeException。
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Throwable) {
            Log.w(TAG, "进入前台失败: $e")
            false
        }
    }

    private fun buildNotification(): Notification {
        // 构造通知的任何一步失败都不能连累「进入前台」这件事：
        // 进不去前台 = 系统 5 秒后判我们超时 = 进程猝死。
        // 所以这里失败了就退回到一个最朴素的通知，保证 startForeground 拿得到东西。
        return try {
            buildRichNotification()
        } catch (e: Throwable) {
            Log.w(TAG, "构造常驻通知失败，退回最小通知: $e")
            buildMinimalNotification()
        }
    }

    /** 完整版常驻通知。 */
    private fun buildRichNotification(): Notification {
        val builder = newBuilder()
        builder
            .setContentTitle("Remember 记账正在后台监听")
            .setContentText("支付通知会自动记进账本")
            .setSmallIcon(R.mipmap.ic_launcher)
            // 常驻通知：用户不能划掉，否则就等于把保活关掉了。
            .setOngoing(true)
            .setShowWhen(false)

        // 点通知回到 App。拿不到启动 Intent 就不设这一项——
        // 硬塞一个 null 给 PendingIntent.getActivity 会抛异常，
        // 那时候整个 App 都会跟着崩。
        try {
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            if (launch != null) {
                builder.setContentIntent(
                    android.app.PendingIntent.getActivity(
                        this,
                        0,
                        launch,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                            android.app.PendingIntent.FLAG_IMMUTABLE
                    )
                )
            }
        } catch (e: Throwable) {
            Log.w(TAG, "设置通知点击跳转失败: $e")
        }

        return builder.build()
    }

    /** 兜底用的最小通知：只要能进前台就行。 */
    private fun buildMinimalNotification(): Notification {
        val builder = newBuilder()
        builder
            .setContentTitle("Remember 记账")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
        return builder.build()
    }

    private fun newBuilder(): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        try {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台监听",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "常驻通知：App 在后台持续监听支付通知并自动记账"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(channel)
        } catch (e: Throwable) {
            Log.w(TAG, "创建通知渠道失败: $e")
        }
    }

    companion object {
        private const val TAG = "FgListener"

        /** 通知渠道 ID。 */
        const val CHANNEL_ID = "remember_background_listener"

        private const val NOTIFICATION_ID = 4101

        /**
         * 确保常驻服务在跑。
         *
         * 已经在跑就什么都不做——每次都启动服务都会白白
         * 触发一次 `onStartCommand`。
         *
         * ## 这里为什么用普通 `startService()` 而不是 `startForegroundService()`
         *
         * `startForegroundService()` 不是普通的启动服务：它会在系统里
         * 挂一个**5~10 秒的看门狗**，要求 App 在这期间调用一次
         * `Service.startForeground()`。超时没调用，系统就抛
         * `ForegroundServiceDidNotStartInTimeException`，
         * **把我们整个进程打死**。
         *
         * 这个异常是系统发起的，App 里 catch 不住；
         * 自己调 `stopSelf()` 也撤不掉那个看门狗。
         *
         * 更要命的是它会形成**崩溃循环**：
         * 一旦出过一次这种崩溃，系统会留下「start requested」的挂起状态，
         * 下一次 `startForegroundService()` 会在**几十毫秒内**被系统判定超时，
         * 再次把进程打死。用户看到的正是「App 直接打不开了」——
         * 点开闪一下就没了，怎么重开都没用。
         * （这个崩溃真刀真枪发生过：崩溃记录里抓到的就是
         *  `ForegroundServiceDidNotStartInTimeException`。）
         *
         * 普通 `startService()` **不挂那个看门狗**：
         * 即便随后 `startForeground()` 被系统拒绝（Android 12+ 的后台启动限制），
         * 也只是这次没进前台，**绝不会猝死**。
         *
         * 前台服务照常建立：`onStartCommand` 里第一件事就是 `startForeground()`，
         * 之后靠 `START_STICKY` 续命。
         */
        fun ensureRunning(context: Context) {
            val appContext = context.applicationContext
            if (!ListenerDiagnostics.isBackgroundMonitoringEnabled(appContext)) return
            if (isRunning(appContext)) return

            try {
                val intent = Intent(appContext, ListenerForegroundService::class.java)
                // 刻意不用 startForegroundService：理由见上面的注释。
                appContext.startService(intent)
                Log.i(TAG, "已请求启动后台常驻服务")
            } catch (e: Throwable) {
                // Android 8+ 不允许在后台启动普通服务，
                // 这里抛的是 IllegalStateException。
                // 起不来不是致命问题：闹钟和 Job 两条腿还在，
                // 用户下次打开 App 时会再试（那时一定在前台，能成功进前台）。
                Log.w(TAG, "启动后台常驻服务失败（可能是后台启动限制）: $e")
            }
        }

        /** 停掉常驻服务（用户关掉「后台常驻监听」时调用）。 */
        fun stop(context: Context) {
            try {
                context.applicationContext.stopService(
                    Intent(context.applicationContext, ListenerForegroundService::class.java)
                )
            } catch (e: Throwable) {
                Log.w(TAG, "停止后台常驻服务失败: $e")
            }
        }

        /**
         * 常驻服务现在是不是真的在跑。
         *
         * 用 `getRunningServices` 查真实状态，而不是靠一个内存里的标记：
         * 标记只能说明「这个进程里曾经创建过服务」，
         * 而服务被系统回收后进程也可能还活着。
         */
        fun isRunning(context: Context): Boolean {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE)
                as? android.app.ActivityManager ?: return false
            return try {
                @Suppress("DEPRECATION")
                am.getRunningServices(Int.MAX_VALUE).any {
                    it.service.className == ListenerForegroundService::class.java.name
                }
            } catch (e: Throwable) {
                Log.w(TAG, "查询常驻服务状态失败: $e")
                false
            }
        }
    }
}
