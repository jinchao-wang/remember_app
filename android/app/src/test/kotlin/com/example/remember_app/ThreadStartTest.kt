package com.example.remember_app

import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 确认 `Thread { ... }` 在 Kotlin 里到底会不会自己启动。
 *
 * 这不是考据，是踩过的坑：
 * `Thread { ... }` 走的是 `java.lang.Thread(Runnable)` 构造器，
 * **它只创建、不启动**——要自己调 `.start()`。
 * 写成 `Thread { ... }` 就等于开了个永远不执行的线程，
 * 结果是 MethodChannel 的结果永远回不去，Dart 那边永远卡在 await。
 */
class ThreadStartTest {

    @Test
    fun `Thread 大括号不会自动启动 必须显式 start`() {
        val latch = CountDownLatch(1)
        val thread = Thread { latch.countDown() }

        // 没调 start()，任务永远不会跑。
        val ranWithoutStart = latch.await(300, TimeUnit.MILLISECONDS)

        // 显式 start() 之后才会跑。
        thread.start()
        val ranAfterStart = latch.await(3, TimeUnit.SECONDS)

        assertTrue("没 start 的 Thread 不该执行", !ranWithoutStart)
        assertTrue("start 之后 Thread 应该执行", ranAfterStart)
    }
}
