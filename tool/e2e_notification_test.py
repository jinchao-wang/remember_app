#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
remember_app —— Android「收付款通知自动记账」端到端验证脚本。

在 Android 模拟器上真实走完整条链路：
    系统通知 -> NotificationListenerService -> PaymentEvents -> EventChannel
    -> Dart PaymentService.handleEvent -> sqflite 落库

每一项都直接查模拟器里的 sqlite 真实数据，不靠肉眼看 UI。
这个脚本在开发过程中找出了「金额取错 / 日期被当金额 / 关键词误判」三个真实缺陷。

前置条件（Windows 示例）：
  1. 模拟器已启动并 adb devices 可见
  2. 已构建 APK：flutter build apk --debug
  3. 已授权通知监听：
     adb shell cmd notification allow_listener \
         com.example.remember_app/com.example.remember_app.PaymentNotificationListenerService

用法：
  python tool/e2e_notification_test.py [apk路径]
"""
import os
import subprocess
import sys
import time

ADB = os.environ.get("ADB", r"D:\toolchain\android-sdk\platform-tools\adb.exe")
DEVICE = os.environ.get("ANDROID_SERIAL", "emulator-5554")
PKG = "com.example.remember_app"
DB = "databases/remember_local.db"
APK = os.environ.get(
    "APK",
    r"D:\wjc\remember\build\app\outputs\flutter-apk\app-debug.apk",
)

PASS, FAIL = [], []


def sh(*args):
    r = subprocess.run([ADB, "-s", DEVICE] + [str(a) for a in args], capture_output=True)
    return r.stdout.decode("utf-8", "replace")


def shell(cmd):
    return sh("shell", cmd)


def log(msg):
    print(msg, flush=True)


def rows():
    """读取 transactions 表全部行。"""
    out = shell(
        f'run-as {PKG} sqlite3 {DB} '
        '"SELECT id,amount,type,category,note,isAuto,sourceApp FROM transactions ORDER BY id;"'
    )
    res = []
    for line in out.replace("\r", "").split("\n"):
        p = line.split("|")
        if len(p) < 7:
            continue
        try:
            res.append(
                {
                    "id": int(p[0]),
                    "amount": float(p[1]),
                    "type": p[2],
                    "category": p[3],
                    "note": p[4],
                    "isAuto": int(p[5]),
                    "sourceApp": p[6],
                }
            )
        except ValueError:
            continue
    return res


def post(tag, title, text, big=False):
    style = "-S bigtext " if big else ""
    shell(f'cmd notification post {style}-t "{title}" {tag} "{text}"')


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append((name, detail))
    log(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))


def listener_granted():
    out = shell("settings get secure enabled_notification_listeners")
    return PKG in out


def ensure_listener():
    """授权通知监听并确认真的生效。

    注意：pm clear / 重装会把系统的通知监听授权一起冲掉，
    而且 install 刚结束时调用 allow_listener 可能不生效（包还在安装收尾），
    所以这里要「授权 -> 校验 -> 重试」，不能只调一次就算数。
    """
    comp = f"{PKG}/{PKG}.PaymentNotificationListenerService"
    for attempt in range(6):
        shell(f"cmd notification allow_listener {comp}")
        time.sleep(1.5)
        if listener_granted():
            log(f"  通知监听授权已生效（第 {attempt + 1} 次尝试）")
            return True
        log(f"  通知监听授权未生效，重试（{attempt + 1}/6）")
        time.sleep(2)
    return False


def wait_listener_connected(timeout=30):
    """等原生监听服务真正连上，否则第一条通知会落在绑定窗口里被丢掉。"""
    end = time.time() + timeout
    while time.time() < end:
        if "通知监听已连接" in shell("logcat -d -v time -s PaymentListener:V"):
            return True
        time.sleep(1.5)
    return False


def warm_up(attempts=5):
    """用一条预热通知实测监听是否真的活着。

    只看「通知监听已连接」日志不够：那条日志只在连接瞬间打一次，
    如果此前已经连上，清过 logcat 就再也等不到它。
    """
    for i in range(attempts):
        shell("logcat -c")
        post("warmup", "预热探测", "收款 ¥0.01")
        time.sleep(3)
        if "detected:" in shell("logcat -d -v time -s PaymentListener:V"):
            log(f"  预热成功，监听已就绪（第 {i + 1} 次尝试）")
            return True
        log(f"  预热未命中（监听可能还在绑定中），重试 {i + 1}/{attempts}")
        time.sleep(2)
    return False


def expect_record(tag, title, text, big=False, timeout=10):
    """投递一条通知，返回新落库的记录（没有则返回 None）。"""
    before = len(rows())
    post(tag, title, text, big=big)
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = rows()
        if len(r) > before:
            return r[-1]
        time.sleep(0.6)
    return None


def expect_no_record(tag, title, text, wait=4):
    """投递一条通知，断言它不产生新记录。"""
    before = len(rows())
    post(tag, title, text)
    time.sleep(wait)
    after = len(rows())
    return before, after


def main():
    if not os.path.exists(APK):
        log(f"APK 不存在：{APK}\n先执行 flutter build apk --debug")
        return 2

    log(f"设备：{DEVICE}\nAPK ：{APK}\n")

    # 干净起点
    shell(f"pm clear {PKG}")
    time.sleep(1)
    r = subprocess.run([ADB, "-s", DEVICE, "install", "-r", "-g", APK], capture_output=True, text=True)
    log("安装：" + (r.stdout or "").strip())
    if not ensure_listener():
        log("通知监听授权失败，无法继续")
        return 2
    shell(f"am start -n {PKG}/.MainActivity")
    time.sleep(5)
    if not warm_up():
        log("监听服务始终没有就绪")
        return 2
    # 预热记录留在库里也无妨：后续用例都用「前后条数差」判断，不受影响。

    # ------------------------------------------------------------ 基础链路
    log("\n=== A. 端到端主链路 ===")
    rec = expect_record("a1", "微信支付", "微信支付收款 ¥12.50", big=True)
    check("微信收款 -> 落库 income 12.50",
          rec is not None and abs(rec["amount"] - 12.50) < .001 and rec["type"] == "income",
          str(rec))
    check("标记为自动记账", rec is not None and rec["isAuto"] == 1, str(rec))
    check("备注保留通知原文", rec is not None and "收款" in (rec["note"] or ""), str(rec))

    rec = expect_record("a2", "支付宝", "你有一笔支出 ¥88.00")
    check("支付宝支出 -> 落库 expense 88.00",
          rec is not None and abs(rec["amount"] - 88.00) < .001 and rec["type"] == "expense",
          str(rec))

    rec = expect_record("a3", "美团外卖", "订单支付成功 ¥32.00")
    check("分类推断为餐饮", rec is not None and rec["category"] == "餐饮", str(rec))

    # ------------------------------------------------------------ 判重
    log("\n=== B. 判重 ===")
    before, after = expect_no_record("a1", "微信支付", "微信支付收款 ¥12.50", wait=5)
    check("重复投递同一笔通知不新增记录", before == after, f"{before}->{after}")

    rec = expect_record("b1", "微信支付", "付款成功 ¥99.00")
    check("同金额但方向相反 -> 单独记一笔 expense",
          rec is not None and rec["type"] == "expense" and abs(rec["amount"] - 99.00) < .001,
          str(rec))

    # ------------------------------------------------------------ 无关通知
    log("\n=== C. 该忽略的通知 ===")
    before, after = expect_no_record("c1", "天气", "明天晴 25.00 摄氏度")
    check("无关通知被忽略", before == after, f"{before}->{after}")

    before, after = expect_no_record("c2", "微信支付", "支付成功")
    check("有关键词但没有金额 -> 不记账", before == after, f"{before}->{after}")

    before, after = expect_no_record("c3", "微信支付", "¥54.54")
    check("只有金额没有任何方向线索 -> 不记账（宁缺毋滥）", before == after, f"{before}->{after}")

    # ------------------------------------------------------------ 金额格式
    log("\n=== D. 金额格式 ===")
    rec = expect_record("d1", "招商银行", "消费 ¥1234.56")
    check("千分位 1234.56",
          rec is not None and abs(rec["amount"] - 1234.56) < .001, str(rec))

    rec = expect_record("d2", "微信支付", "收款 37.77元")
    check("「元」后缀 37.77",
          rec is not None and abs(rec["amount"] - 37.77) < .001, str(rec))

    rec = expect_record("d3", "微信支付", "收款 ￥1111.11")
    check("全角￥ + 千分位 1111.11",
          rec is not None and abs(rec["amount"] - 1111.11) < .001, str(rec))

    rec = expect_record("d4", "微信支付", "收款 ¥123456789.00")
    check("九位金额 123456789.00",
          rec is not None and abs(rec["amount"] - 123456789.0) < .01, str(rec))

    rec = expect_record("d5", "微信支付", "支付成功 ¥0.01")
    check("最小金额 0.01",
          rec is not None and abs(rec["amount"] - 0.01) < .001, str(rec))

    # ------------------------------------------------------------ 方向
    log("\n=== E. 收支方向 ===")
    rec = expect_record("e1", "微信支付", "微信转账到账 ¥2222.22")
    check("「转账到账」-> income",
          rec is not None and rec["type"] == "income" and abs(rec["amount"] - 2222.22) < .001,
          str(rec))

    rec = expect_record("e2", "微信支付", "转账成功 ¥3333.33")
    check("「转账成功」-> expense（歧义词默认流出）",
          rec is not None and rec["type"] == "expense" and abs(rec["amount"] - 3333.33) < .001,
          str(rec))

    # 「支付宝」含「支付」二字，早先没从正文里剥掉，
    # 导致这条收入通知被当成支出——收入记成支出比不记还糟。
    rec = expect_record("e2b", "支付宝", "到账 ¥12.00")
    check("「支付宝 到账」-> income（品牌名不能当方向词）",
          rec is not None and rec["type"] == "income" and abs(rec["amount"] - 12.00) < .001,
          str(rec))

    rec = expect_record("e3", "微信支付", "提现到零钱 ¥4444.44")
    check("「提现」-> expense",
          rec is not None and rec["type"] == "expense" and abs(rec["amount"] - 4444.44) < .001,
          str(rec))

    rec = expect_record("e4", "微信支付", "到帐 ¥5555.55")
    check("「到帐」异体写法 -> income",
          rec is not None and rec["type"] == "income", str(rec))

    rec = expect_record("e5", "工商银行", "入账 ¥6666.66")
    check("「入账」-> income",
          rec is not None and rec["type"] == "income", str(rec))

    rec = expect_record("e6", "微信支付", "+¥13.13")
    check("正号金额 -> income",
          rec is not None and rec["type"] == "income" and abs(rec["amount"] - 13.13) < .001,
          str(rec))

    rec = expect_record("e7", "微信支付", "-¥14.14")
    check("负号金额 -> expense",
          rec is not None and rec["type"] == "expense" and abs(rec["amount"] - 14.14) < .001,
          str(rec))

    # ------------------------------------------------------------ 回归：取错金额
    log("\n=== F. 回归：一个通知里有多个数字 ===")
    rec = expect_record("f1", "招商银行", "余额 1000.00 元，付款成功 77.77")
    check("余额在前 -> 取实付 77.77（不是 1000.00）",
          rec is not None and abs(rec["amount"] - 77.77) < .001, str(rec))

    rec = expect_record("f2", "招商银行", "付款成功 88.88，余额 2000.00 元")
    check("余额在后 -> 取实付 88.88（不是 2000.00）",
          rec is not None and abs(rec["amount"] - 88.88) < .001, str(rec))

    rec = expect_record("f3", "工商银行", "尾号 8888 的储蓄卡消费 12.34 元")
    check("卡号尾号不被当成金额",
          rec is not None and abs(rec["amount"] - 12.34) < .001, str(rec))

    rec = expect_record("f4", "账单助手", "2024.10.05 到账 99.99")
    check("日期不被当成金额（不是 2024.10）",
          rec is not None and abs(rec["amount"] - 99.99) < .001, str(rec))

    rec = expect_record("f5", "账单助手", "2024.10.05 到账 ¥77.66")
    check("带货币符号时也不受日期干扰",
          rec is not None and abs(rec["amount"] - 77.66) < .001, str(rec))

    # ------------------------------------------------------------ 离线缓存补发
    log("\n=== G. App 未运行时收到通知 ===")
    shell(f"am force-stop {PKG}")
    time.sleep(2)
    before = len(rows())
    post("g1", "微信支付", "收款到账 ¥66.60")
    time.sleep(3)
    check("App 停止期间不立即落库（事件进了原生缓存）", len(rows()) == before,
          f"before={before} now={len(rows())}")
    shell(f"am start -n {PKG}/.MainActivity")
    # debug 包冷启动在负载较高的模拟器上要 18 秒以上（Activity 才算 displayed），
    # 补记发生在 Dart 侧起来之后，所以这里必须给足等待时间，
    # 否则会被误判成「补记失败」。
    deadline = time.time() + 90
    rec = None
    while time.time() < deadline:
        r = rows()
        if len(r) > before:
            rec = r[-1]
            break
        time.sleep(0.8)
    check("启动 App 后补记成功",
          rec is not None and abs(rec["amount"] - 66.60) < .001 and rec["type"] == "income",
          str(rec))

    # ------------------------------------------------------------ 汇总
    log("\n" + "=" * 64)
    log(f"通过 {len(PASS)} 项，失败 {len(FAIL)} 项")
    for n, d in FAIL:
        log(f"  FAILED: {n}  {d}")
    log("=" * 64)
    log("\n最终 transactions 表：")
    for r in rows():
        log(f"  {r}")
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
