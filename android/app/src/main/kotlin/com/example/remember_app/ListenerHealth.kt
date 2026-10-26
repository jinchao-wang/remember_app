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
}
