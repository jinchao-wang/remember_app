package com.example.remember_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * PaymentParser 的 JVM 单元测试。
 *
 * 这些用例全部来自真机/模拟器端到端测试中实际暴露出来的缺陷，
 * 每一条都对应一个真实存在的错账场景。
 */
class PaymentParserTest {

    private fun parse(content: String): PaymentParser.Result? = PaymentParser.parse(content)

    private fun amount(content: String): Double? = parse(content)?.amount

    private fun type(content: String): String? = parse(content)?.type

    // ------------------------------------------------------------ 基础方向

    @Test
    fun `微信收款记为收入`() {
        val r = parse("微信支付 微信支付收款 ¥12.50")
        assertNotNull(r)
        assertEquals(12.5, r!!.amount, 0.0001)
        assertEquals(PaymentParser.TYPE_INCOME, r.type)
    }

    @Test
    fun `支付宝付款记为支出`() {
        val r = parse("支付宝 付款成功 ¥88.00")
        assertNotNull(r)
        assertEquals(88.0, r!!.amount, 0.0001)
        assertEquals(PaymentParser.TYPE_EXPENSE, r.type)
    }

    @Test
    fun `红包到账记为收入`() {
        val r = parse("微信支付 微信支付 红包 ¥5.00")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_INCOME, r!!.type)
    }

    @Test
    fun `银行消费记为支出`() {
        val r = parse("招商银行 消费 ¥20.00")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_EXPENSE, r!!.type)
    }

    @Test
    fun `转账到账记为收入`() {
        val r = parse("微信支付 微信转账到账 ¥200.00")
        assertNotNull(r)
        assertEquals(200.0, r!!.amount, 0.0001)
        assertEquals(PaymentParser.TYPE_INCOME, r.type)
    }

    @Test
    fun `转账成功默认为支出`() {
        val r = parse("微信支付 转账成功 ¥500.00")
        assertNotNull(r)
        assertEquals(500.0, r!!.amount, 0.0001)
        assertEquals(PaymentParser.TYPE_EXPENSE, r.type)
    }

    @Test
    fun `提现记为支出`() {
        val r = parse("微信支付 提现到零钱 ¥300.00")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_EXPENSE, r!!.type)
    }

    @Test
    fun `到帐是到账的异体写法`() {
        val r = parse("微信支付 到帐 ¥15.00")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_INCOME, r!!.type)
    }

    @Test
    fun `入账记为收入`() {
        val r = parse("工商银行 入账 ¥60.00")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_INCOME, r!!.type)
    }

    @Test
    fun `收到转账记为收入而不是支出`() {
        // 只命中歧义词「转账」时默认按流出处理，会把收款记反方向。
        val r = parse("微信支付 收到转账 14.52元")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_INCOME, r!!.type)
        assertEquals(14.52, r.amount, 0.0001)
    }

    @Test
    fun `微信真实付款通知文案可以解析`() {
        // 真实通知正文形如：
        // 「微信支付」—「你于2026年10月20日,使用付款功能交易成功支付12.50元」
        val r = parse("微信支付 你于2026年10月20日,使用付款功能交易成功支付12.50元")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_EXPENSE, r!!.type)
        assertEquals(12.50, r.amount, 0.0001)
    }

    @Test
    fun `银行尾号消费通知可以解析`() {
        val r = parse("招商银行 您尾号8888的储蓄卡于10月20日消费 20.58元")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_EXPENSE, r!!.type)
        assertEquals(20.58, r.amount, 0.0001)
    }

    @Test
    fun `品牌名里的支付不会把收款通知误判成支出`() {
        // 标题「微信支付」含「支付」二字，不能因此把收款当成付款。
        val r = parse("微信支付 收款 ¥12.50")
        assertNotNull(r)
        assertEquals(PaymentParser.TYPE_INCOME, r!!.type)
    }

    // ------------------------------------------------------------ 金额格式

    @Test
    fun `支持元后缀`() {
        assertEquals(12.5, amount("微信支付 收款 12.50元")!!, 0.0001)
    }

    @Test
    fun `支持全角人民币符号与千分位`() {
        assertEquals(1234.56, amount("微信支付 收款 ￥1,234.56")!!, 0.0001)
    }

    @Test
    fun `支持九位金额`() {
        assertEquals(123456789.0, amount("微信支付 收款 ¥123456789.00")!!, 0.0001)
    }

    @Test
    fun `支持最小金额`() {
        assertEquals(0.01, amount("微信支付 支付成功 ¥0.01")!!, 0.0001)
    }

    // ------------------------------------------------------------ 回归：多个数字时取错金额

    @Test
    fun `余额在前时应取后面的实付金额`() {
        // 早先的实现取第一个匹配，把余额 1000.00 记成了消费金额。
        assertEquals(51.51, amount("招商银行 余额 1000.00 元，付款成功 51.51")!!, 0.0001)
    }

    @Test
    fun `余额在后时应取前面的实付金额`() {
        assertEquals(52.52, amount("招商银行 付款成功 52.52，余额 2000.00 元")!!, 0.0001)
    }

    @Test
    fun `卡号尾号不应被当成金额`() {
        assertEquals(53.53, amount("工商银行 尾号 8888 的储蓄卡消费 53.53 元")!!, 0.0001)
    }

    @Test
    fun `日期不应被当成金额`() {
        // 早先的实现会把「2024.10」当成金额。
        assertEquals(41.41, amount("账单助手 2024.10.05 到账 41.41")!!, 0.0001)
    }

    @Test
    fun `带货币符号时日期也不会干扰`() {
        assertEquals(41.42, amount("账单助手 2024.10.05 到账 ¥41.42")!!, 0.0001)
    }

    // ------------------------------------------------------------ 该忽略的通知

    @Test
    fun `无关通知不记账`() {
        assertNull(parse("天气 明天晴 25.00 摄氏度"))
    }

    @Test
    fun `有关键词但没有金额不记账`() {
        assertNull(parse("微信支付 支付成功"))
    }

    @Test
    fun `只有金额没有任何方向线索时不记账`() {
        // 方向猜错会往账本里塞一条错误的收支，宁可漏记。
        assertNull(parse("微信支付 ¥54.54"))
    }

    @Test
    fun `带正负号的金额可以判断方向`() {
        assertEquals(PaymentParser.TYPE_INCOME, type("微信支付 +¥9.99"))
        assertEquals(PaymentParser.TYPE_EXPENSE, type("微信支付 -¥9.99"))
    }

    @Test
    fun `日期里的连字符不会被当成负号`() {
        assertNull(parse("账单助手 2024-10-05 ¥9.99"))
    }

    // ------------------------------------------------------------ 失败原因诊断
    //
    // 用户报「有通知但没记账」时，必须能说清楚到底卡在哪一步：
    // 是没金额，还是没方向。这两种原因在 App 里要分别显示。

    @Test
    fun `诊断会说明识别成功`() {
        val d = PaymentParser.diagnose("微信支付 付款成功 ¥12.50")
        assertNotNull(d.result)
        assertEquals(12.5, d.result!!.amount, 0.0001)
        assertEquals("已识别", d.reason)
    }

    @Test
    fun `诊断会说明缺少金额`() {
        val d = PaymentParser.diagnose("微信支付 支付成功")
        assertNull(d.result)
        assertEquals("判断出了收支方向，但没找到金额", d.reason)
    }

    @Test
    fun `诊断会说明缺少方向`() {
        val d = PaymentParser.diagnose("微信支付 ¥54.54")
        assertNull(d.result)
        assertEquals("没有收支关键词，也没有金额正负号", d.reason)
    }

    @Test
    fun `诊断会说明正文为空`() {
        val d = PaymentParser.diagnose("   ")
        assertNull(d.result)
        assertEquals("通知正文为空", d.reason)
    }

    @Test
    fun `诊断会说明是按正负号判断的方向`() {
        val d = PaymentParser.diagnose("微信支付 +¥9.99")
        assertNotNull(d.result)
        assertEquals(PaymentParser.TYPE_INCOME, d.result!!.type)
        assertEquals("按金额正负号判断方向", d.reason)
    }
}
