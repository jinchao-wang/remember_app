package com.example.remember_app

/**
 * 判断通知监听服务「还活着没有」的纯逻辑。
 *
 * ## 为什么要单独抽出来
 *
 * 用户报的现象是「刚装上好使，过几天就收不到任何支付通知」。
 * 修这个问题的关键是**分清两种完全不同的故障**：
 *
 * 1. **绑定掉了**：系统解绑之后没绑回来。
 *    特征是连一条通知（连聊天消息）都收不到。
 * 2. **绑定还在，但没认出来**：通知照收，只是文案没被解析成账单。
 *    特征是聊天消息照常收到，只有支付类通知没记账。
 *
 * 第 2 种情况如果按第 1 种去处理（禁用再启用组件），
 * 系统会认为这个监听器「反复绑定失败」并临时拉黑它——反而更糟。
 * 所以必须有一个可靠的「服务还活着吗」的判据。
 *
 * 判据就是 [ListenerDiagnostics] 里记的 `lastEventAt`：
 * **任何**一条通知（聊天消息也算）都会刷新它。
 * 只要它还在往前走，服务就是活的。
 *
 * 这个类是纯 Kotlin，没有 Android 依赖，可以在 JVM 上直接写单元测试。
 */
object ListenerHealth {

    /**
     * 「最近还收到过通知」的时间窗口：30 分钟。
     *
     * 半小时内收到过任意一条通知，就认为服务是活的。
     * 取半小时是因为：手机放一晚上没通知很正常，
     * 但只要用户还在正常用手机，收聊天消息是分分钟的事。
     */
    const val ALIVE_WINDOW_MS = 30L * 60 * 1000

    /**
     * 最近还收到过任意通知吗。
     *
     * @param lastEventAt 最后一次收到任意通知的时间；0 表示从来没收到过。
     * @param now 当前时间。
     */
    fun isRecentlyAlive(lastEventAt: Long, now: Long): Boolean {
        if (lastEventAt <= 0) return false
        val elapsed = now - lastEventAt
        // elapsed < 0 说明设备时间被往回调过，宁可当成「不活跃」也不要误判。
        return elapsed in 0 until ALIVE_WINDOW_MS
    }

    /**
     * 绑定确实掉过吗。
     *
     * 判据是「最后一次事件是断开，不是连接」——
     * 服务被系统直接杀掉时不会回调断开，
     * 所以「连接时间晚于断开时间」就意味着现在确实是断的。
     *
     * @param connectedAt 最后一次连上系统的时间；0 表示从来没连上过。
     * @param disconnectedAt 最后一次与系统断开的时间；0 表示从来没断开过。
     */
    fun isKnownDead(connectedAt: Long, disconnectedAt: Long): Boolean {
        if (connectedAt <= 0) return true
        return disconnectedAt > connectedAt
    }

    /**
     * 进程/服务被杀之后，给系统留的「自己会回来」的时间。
     *
     * 进程被系统回收并不等于监听彻底完了：系统通常会在下一次需要时
     * 重新绑定通知监听服务，`onListenerConnected` 随之回调。
     * 所以刚被杀的一段时间内不能急着动组件，得先给系统一点机会。
     */
    const val RECONNECT_GRACE_MS = 5L * 60 * 1000

    /**
     * 「禁用/启用组件」这种重手段，两次之间至少隔多久。
     *
     * 这招能治好 `requestRebind` 治不了的绑定僵死，但有副作用：
     * 系统可能把这个「反复绑定失败」的监听器临时拉黑。
     * 所以自动路径上必须限频——一天最多自动来一次，
     * 剩下的交给用户手动点「重新连接监听服务」。
     */
    const val ESCALATE_MIN_INTERVAL_MS = 6L * 60 * 60 * 1000

    /**
     * 「已经授权，但监听服务从来没连上过」的宽限期。
     *
     * ## 为什么需要这一条
     *
     * 用户报的是「早上刚装上，中午付款没记账上，点了重新监听按钮才好」。
     * 手动那条按钮走的是**重置组件**（disable -> enable），
     * 而自动路径当时够不着这一招：
     * - 「进程被杀过」——刚装的 App 根本没被杀过，没有证据；
     * - 「系统明确断开过」——从头到尾没连上过，也就谈不上断开。
     *
     * 两条硬证据都不成立，自动路径就只会不停地 `requestRebind`，
     * 而 `requestRebind` 对「绑定僵死」经常什么也不做——
     * 于是自动修复永远修不好，只能等用户手动点按钮。
     *
     * ## 为什么这不是误伤
     *
     * 用户在系统设置里勾上「通知使用权」之后，系统会在**几秒内**
     * 把监听服务绑上来（勾选动作本身就会触发一次 `requestRebind`）。
     * 授权了 10 分钟还从来没连上过，就只可能是绑定真的僵死了。
     */
    const val NEVER_CONNECTED_GRACE_MS = 10L * 60 * 1000

    /**
     * 要不要升级到「禁用/启用组件」这种重手段。
     *
     * ## 为什么要分级
     *
     * 社区里公认的两招：
     * - `requestRebind()`：官方接口，没有副作用，但**服务已经被系统解绑之后
     *   它经常什么也不做**（官方 issue 长期未修）；
     * - 禁用再启用组件：能强制系统丢掉旧绑定重新建立，管用，但有副作用。
     *
     * 之前的实现只有用户手动点按钮时才会走第二招，
     * 自动保活每 15 分钟调一次 `requestRebind`——在「绑定僵死」这种
     * 最常见的故障上，这等于**一直在空转**，所以用户看到的就是
     * 「刚装上好使，过几天就再也收不到了」。
     *
     * ## 判定不能只靠「多久没收到通知」
     *
     * 「半小时没收到通知」在用户安静的手机上完全正常，
     * 拿它当证据会动不动就误伤（误伤一次，系统可能把我们拉黑，更糟）。
     * 所以这里只认三种**硬证据**：
     *
     * 1. **已经授权，但从来没连上过**——
     *    系统该绑而没绑，绑定从一开始就是死的；
     * 2. **进程被杀过，而且之后再没连上过**——
     *    系统把我们杀了，却没把我们绑回来；
     * 3. **系统明确回调过断开**，而且过了宽限期还是没连上。
     *
     * @param connectedAt 最后一次连上系统的时间。
     * @param disconnectedAt 最后一次与系统断开的时间。
     * @param killedAt 进程最后一次被系统结束的时间；0 表示没有这个记录。
     * @param lastEscalateAt 上一次动用重手段的时间；0 表示从来没动过。
     * @param now 当前时间。
     * @param authorizedSince 第一次发现「系统里已经勾了通知使用权」的时间；
     *   0 表示还没观察到授权。
     * @param processStartedAt 当前进程启动的时间；0 表示不知道。
     */
    fun shouldEscalate(
        connectedAt: Long,
        disconnectedAt: Long,
        killedAt: Long,
        lastEscalateAt: Long,
        now: Long,
        authorizedSince: Long = 0L,
        processStartedAt: Long = 0L
    ): Boolean {
        // 限频：副作用太大，不能频繁用。
        if (lastEscalateAt > 0 && now - lastEscalateAt < ESCALATE_MIN_INTERVAL_MS) {
            return false
        }

        // 证据一：已经授权，监听服务却从来没连上过。
        //
        // 这正是「刚装上就不生效、点一下重新监听才好」的现场：
        // 自动路径以前拿不到任何证据，只能一直空转 requestRebind。
        if (authorizedSince > 0 && connectedAt <= 0 &&
            now - authorizedSince > NEVER_CONNECTED_GRACE_MS
        ) {
            return true
        }

        // 证据二：系统明确断开了，之后一直没回来。
        if (disconnectedAt > connectedAt &&
            now - disconnectedAt > RECONNECT_GRACE_MS
        ) {
            return true
        }

        // 证据三：进程被杀过，之后再没连上过。
        if (killedAt > 0 && connectedAt <= killedAt &&
            now - killedAt > RECONNECT_GRACE_MS
        ) {
            // 还要求「进程被杀之后确实重新起来过」。
            //
            // 否则用户刚把 App 打开（系统还没来得及回调 onListenerConnected）
            // 就会被误判成绑定僵死，白白动一次组件。
            if (processStartedAt <= 0L) return true
            if (processStartedAt > killedAt &&
                now - processStartedAt > RECONNECT_GRACE_MS
            ) {
                return true
            }
        }

        return false
    }
}
