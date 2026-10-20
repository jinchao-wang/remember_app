package com.example.remember_app

/**
 * 支付通知解析器。
 *
 * 刻意不引用任何 Android 类（只用 kotlin stdlib），这样同一份逻辑可以
 * 在 JVM 上直接跑单元测试，见 android/app/src/test/kotlin/.../PaymentParserTest.kt。
 */
object PaymentParser {

    const val TYPE_EXPENSE = "expense"
    const val TYPE_INCOME = "income"

    /** 解析结果。 */
    data class Result(val amount: Double, val type: String)

    /**
     * 支出方向词。
     *
     * 「支付」「付款」是裸词，而通知标题几乎总是「微信支付」这类品牌名，
     * 同样含「支付」二字。匹配前会先剥掉品牌名（见 [walletNames]），
     * 否则微信的收款通知会被误判成支出。
     */
    private val expenseKeywords = listOf(
        "支付成功", "付款成功", "支付", "付款", "消费", "支出", "扣款", "扣费",
        "购买", "下单", "还款", "充值", "转出", "提现", "交易成功", "已支付", "已付款"
    )

    /**
     * 收入方向词。
     *
     * 「到帐」是「到账」的常见异体写法，必须一起覆盖，否则这类通知会整条漏掉。
     */
    private val incomeKeywords = listOf(
        "收款", "到账", "到帐", "转入", "入账", "存入", "收入",
        "红包", "退款", "退回", "返现"
    )

    /**
     * 「转账」本身不表方向：单独的「转账成功」多为转出（记支出），
     * 而「微信转账到账」是流入。若塞进支出词表，后一种会被误判。
     */
    private val ambiguousKeywords = listOf("转账")

    /**
     * 匹配方向词之前先剥掉的钱包品牌名。
     *
     * 只列「本身就含方向词」的名字（几乎都含「支付」二字）。
     * 用等长空格替换，保持字符下标不变，金额候选的位置才仍然对得上原文。
     */
    private val walletNames = listOf(
        "微信支付", "京东支付", "抖音支付", "美团支付", "百度支付",
        "Apple Pay", "Google Pay", "银联云闪付", "云闪付"
    )

    /** 带货币符号的金额：¥12.50 / ￥1,234.56 / RMB 88 */
    private val symbolRegex =
        Regex("""(?:¥|￥|RMB)\s*(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)""")

    /** 「元」后缀的金额：12.50元 */
    private val yuanRegex =
        Regex("""(?<![\d.])(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)\s*元""")

    /**
     * 裸的两位小数兜底。
     *
     * 两个断言缺一不可：
     * - `(?<![\d.])` 防止从「2024.10.05」这类日期里截出一半
     * - `(?!\.\d)`   同上，阻止「2024.10」被当成金额
     */
    private val plainRegex = Regex("""(?<![\d.])\d{1,7}\.\d{2}(?!\.\d)""")

    /**
     * 完全没有方向词时，靠金额前的正负号判断（部分钱包的收款通知写成 +¥12.50）。
     * 强制要求带货币符号，避免把「剩余 -5.00 个」之类的普通通知误判成交易。
     */
    private val signedRegex =
        Regex("""(?<![\d])([+-])\s*(?:¥|￥|RMB)\s*(\d{1,9}(?:,\d{3})*(?:\.\d{1,2})?)""")

    /**
     * 解析一条通知正文。
     *
     * @return 能识别出金额和收支方向时返回结果，否则 null（表示不记账）。
     */
    fun parse(rawContent: String): Result? {
        if (rawContent.isBlank()) return null

        // 等长替换，保留字符下标，金额候选的位置才对得上。
        val content = walletNames.fold(rawContent) { acc, name ->
            acc.replace(name, " ".repeat(name.length))
        }

        val isExpense = expenseKeywords.any { content.contains(it) }
        val isIncome = incomeKeywords.any { content.contains(it) }
        val isAmbiguous = ambiguousKeywords.any { content.contains(it) }

        if (!isExpense && !isIncome && !isAmbiguous) {
            // 没有任何方向线索：只能靠金额前的正负号。
            // 连正负号都没有就宁可漏记——方向猜错会往账本里塞一条错误的收支。
            val signed = signedRegex.find(content) ?: return null
            val value = signed.groupValues[2].replace(",", "").toDoubleOrNull() ?: return null
            val type = if (signed.groupValues[1] == "+") TYPE_INCOME else TYPE_EXPENSE
            return Result(value, type)
        }

        val type = resolveType(isExpense, isIncome)
        val anchor = findAnchor(content, isExpense, isIncome)
        val amount = pickAmount(content, anchor) ?: return null
        return Result(amount, type)
    }

    /**
     * 收支方向判定。收入词与支出词同时命中时以支出为准（保持原有行为），
     * 只命中歧义词「转账」时默认按流出处理。
     */
    fun resolveType(isExpense: Boolean, isIncome: Boolean): String = when {
        isIncome && !isExpense -> TYPE_INCOME
        isExpense -> TYPE_EXPENSE
        isIncome -> TYPE_INCOME
        else -> TYPE_EXPENSE
    }

    /**
     * 找到决定本次收支方向的那个关键词所在区间。
     *
     * 收入、支出词同时命中时以支出为准，与 [resolveType] 保持一致。
     */
    private fun findAnchor(
        content: String,
        isExpense: Boolean,
        isIncome: Boolean
    ): Pair<Int, Int>? {
        val preferred = when {
            isExpense -> expenseKeywords + ambiguousKeywords
            isIncome -> incomeKeywords + ambiguousKeywords
            else -> ambiguousKeywords
        }
        val fallback = expenseKeywords + incomeKeywords + ambiguousKeywords

        var best: Pair<Int, Int>? = null
        for (kw in preferred) {
            val i = content.indexOf(kw)
            if (i >= 0 && isBetterAnchor(i, kw.length, best)) best = i to (i + kw.length)
        }
        if (best != null) return best
        for (kw in fallback) {
            val i = content.indexOf(kw)
            if (i >= 0 && isBetterAnchor(i, kw.length, best)) best = i to (i + kw.length)
        }
        return best
    }

    /** 起点相同时取更长的关键词（「付款成功」优于「付款」）。 */
    private fun isBetterAnchor(index: Int, length: Int, best: Pair<Int, Int>?): Boolean {
        if (best == null) return true
        if (index != best.first) return index < best.first
        return length > best.second - best.first
    }

    private const val KIND_SYMBOL = 0
    private const val KIND_YUAN = 1
    private const val KIND_PLAIN = 2

    private data class AmountCandidate(
        val value: Double,
        val start: Int,
        val end: Int,
        val kind: Int
    )

    /** 收集正文里所有可能的金额，并带上位置。 */
    private fun collectAmounts(content: String): List<AmountCandidate> {
        val out = ArrayList<AmountCandidate>()

        symbolRegex.findAll(content).forEach { m ->
            val raw = m.groupValues[1]
            val v = raw.replace(",", "").toDoubleOrNull() ?: return@forEach
            val start = m.range.first + m.value.indexOf(raw)
            out.add(AmountCandidate(v, start, start + raw.length, KIND_SYMBOL))
        }

        yuanRegex.findAll(content).forEach { m ->
            val raw = m.groupValues[1]
            val v = raw.replace(",", "").toDoubleOrNull() ?: return@forEach
            val start = m.range.first + m.value.indexOf(raw)
            out.add(AmountCandidate(v, start, start + raw.length, KIND_YUAN))
        }

        plainRegex.findAll(content).forEach { m ->
            val v = m.value.replace(",", "").toDoubleOrNull() ?: return@forEach
            out.add(AmountCandidate(v, m.range.first, m.range.last + 1, KIND_PLAIN))
        }

        return out
    }

    /**
     * 挑出「本次交易真正的金额」。
     *
     * 一条通知里经常有多个数字，比如银行通知
     * 「余额 1000.00 元，付款成功 51.51」——早先的实现取第一个匹配，
     * 会把余额当成消费金额记下来。
     *
     * 规则：取**离方向关键词最近**的那个金额；距离相同时优先取关键词后面的，
     * 再相同时优先带货币符号的。
     */
    private fun pickAmount(content: String, anchor: Pair<Int, Int>?): Double? {
        val candidates = collectAmounts(content)
        if (candidates.isEmpty()) return null

        if (anchor == null) {
            return candidates.firstOrNull { it.kind == KIND_SYMBOL }?.value
                ?: candidates.firstOrNull { it.kind == KIND_YUAN }?.value
                ?: candidates.first().value
        }

        val anchorStart = anchor.first
        val anchorEnd = anchor.second

        return candidates.minWithOrNull(
            compareBy<AmountCandidate> { gap(it, anchorStart, anchorEnd) }
                .thenBy { if (it.start >= anchorEnd) 0 else 1 }
                .thenBy { it.kind }
                .thenBy { it.start }
        )?.value
    }

    /** 金额区间与关键词区间之间的间隔；两者重叠时为 0。 */
    private fun gap(c: AmountCandidate, anchorStart: Int, anchorEnd: Int): Int = when {
        c.end <= anchorStart -> anchorStart - c.end
        c.start >= anchorEnd -> c.start - anchorEnd
        else -> 0
    }
}
