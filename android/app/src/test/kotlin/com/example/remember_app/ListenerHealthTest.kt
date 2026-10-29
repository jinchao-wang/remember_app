package com.example.remember_app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [ListenerHealth] 的 JVM 单元测试。
 *
 * 这些判据决定了「要不要去重置组件绑定」——
 * 判断错了要么治不好病，要么把监听器搞得更糟，所以要有测试兜住。
 */
class ListenerHealthTest {

    private val now = 1_700_000_000_000L

    // ------------------------------------------------------------ 存活判定

    @Test
    fun `从来没收到过通知 意味着 不算活着`() {
        assertFalse(ListenerHealth.isRecentlyAlive(0L, now))
    }

    @Test
    fun `刚刚收到过通知 意味着 算活着`() {
        assertTrue(ListenerHealth.isRecentlyAlive(now - 60_000L, now))
    }

    @Test
    fun `半小时内收到过通知 意味着 算活着`() {
        assertTrue(
            ListenerHealth.isRecentlyAlive(
                now - ListenerHealth.ALIVE_WINDOW_MS + 1,
                now
            )
        )
    }

    @Test
    fun `刚好卡在窗口边界外 意味着 不算活着`() {
        assertFalse(
            ListenerHealth.isRecentlyAlive(
                now - ListenerHealth.ALIVE_WINDOW_MS,
                now
            )
        )
    }

    @Test
    fun `很久没收到通知 意味着 不算活着`() {
        // 这正是用户报的故障现场：绑定僵死，一条通知都收不到。
        assertFalse(ListenerHealth.isRecentlyAlive(now - 3 * 60 * 60 * 1000L, now))
    }

    @Test
    fun `设备时间被往回调过 意味着 不算活着`() {
        // 宁可保守一点，也不要因为时钟跳变就误判成「活着」而跳过治疗。
        assertFalse(ListenerHealth.isRecentlyAlive(now + 60_000L, now))
    }

    // ------------------------------------------------------------ 断开判定

    @Test
    fun `从来没连上过 意味着 算断开`() {
        assertTrue(ListenerHealth.isKnownDead(0L, 0L))
    }

    @Test
    fun `最后一次事件是断开 意味着 算断开`() {
        assertTrue(ListenerHealth.isKnownDead(1000L, 2000L))
    }

    @Test
    fun `断开之后又连上了 意味着 算正常`() {
        assertFalse(ListenerHealth.isKnownDead(3000L, 2000L))
    }

    @Test
    fun `只连上过、没断开过 意味着 算正常`() {
        assertFalse(ListenerHealth.isKnownDead(1000L, 0L))
    }

    // ------------------------------------------------------- 升级重手段的判定

    @Test
    fun `进程被杀之后一直没连回来 意味着 该升级了`() {
        // 这就是「时间久了监听就没了」的现场：
        // 系统杀了进程，却没把监听服务绑回来。
        assertTrue(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 10 * 60 * 1000L,
                disconnectedAt = 0L,
                killedAt = now - 6 * 60 * 1000L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }

    @Test
    fun `进程被杀之后很快又连上了 意味着 不用升级`() {
        // 系统把服务绑回来了，说明一切正常，不该动组件。
        assertFalse(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 60_000L,
                disconnectedAt = 0L,
                killedAt = now - 5 * 60 * 1000L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }

    @Test
    fun `刚被杀还在宽限期内 意味着 不用升级`() {
        // 系统通常会在需要时自己绑回来，别急着动组件。
        assertFalse(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 10 * 60 * 1000L,
                disconnectedAt = 0L,
                killedAt = now - 60_000L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }

    @Test
    fun `系统明确断开且一直没回来 意味着 该升级了`() {
        assertTrue(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 20 * 60 * 1000L,
                disconnectedAt = now - 6 * 60 * 1000L,
                killedAt = 0L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }

    @Test
    fun `只是很久没收到通知 意味着 不用升级`() {
        // 用户安静的手机上半天没通知太正常了。
        // 没有硬证据就动组件，误伤一次可能被系统拉黑，更糟。
        assertFalse(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 8 * 60 * 60 * 1000L,
                disconnectedAt = 0L,
                killedAt = 0L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }

    @Test
    fun `刚升级过不到六小时 意味着 不再升级`() {
        // 重置组件有副作用（系统可能拉黑监听器），必须限频。
        assertFalse(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 10 * 60 * 1000L,
                disconnectedAt = 0L,
                killedAt = now - 6 * 60 * 1000L,
                lastEscalateAt = now - 60 * 60 * 1000L,
                now = now
            )
        )
    }

    @Test
    fun `距上次升级超过六小时 意味着 又可以升级`() {
        assertTrue(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 10 * 60 * 1000L,
                disconnectedAt = 0L,
                killedAt = now - 6 * 60 * 1000L,
                lastEscalateAt = now - 7 * 60 * 60 * 1000L,
                now = now
            )
        )
    }

    @Test
    fun `一切正常时 意味着 不用升级`() {
        assertFalse(
            ListenerHealth.shouldEscalate(
                connectedAt = now - 60_000L,
                disconnectedAt = 0L,
                killedAt = 0L,
                lastEscalateAt = 0L,
                now = now
            )
        )
    }
}
