# Remember 记账

本地优先的 Flutter 记账应用，Android 支持支付通知自动记录，iOS 手动记账。数据仅保存在本地设备，不上传服务器。

## 功能

- 本地优先：SQLite 本地存储，不依赖网络
- 自动记录（Android）：监听支付类通知，自动生成账单，支持手动修改且不会被后续通知覆盖
- 手动新增/编辑/删除：跨平台统一
- 统计：日/月收支、分类占比、近 30 天趋势
- CSV 导入导出：Settings -> 数据管理
- Material 3 现代界面

## 目录

- lib/ Flutter 业务代码
- android/ Android 原生：NotificationListenerService 解析通知
- .github/workflows/ Android APK / iOS IPA 自动化构建（参考 D:\wjc\vidio）

## 本地运行

```bash
flutter create --platforms=android,ios --project-name remember_app --org com.example .
flutter pub get
flutter run
```
> 注：首次在已有仓库运行 flutter create 用于补齐平台脚手架，已有文件不会被覆盖。

## Android 支付通知

1. 打开系统设置 -> 通知使用权 / 通知监听器
2. 开启 “Remember 记账” 的通知监听权限
3. 常见支付 App 的关键字已内置匹配，可在设置中查看是否已开启

### 工作方式

- 监听服务由系统绑定维持，**App 未运行时收到的支付通知不会被丢弃**：事件会先写入
  SharedPreferences 缓存（最多 200 条），下次打开 App 时自动补记，并还原通知的原始
  发生日期，而不是记成补记当天的日期。
- 同一来源 + 同金额 + 同收支方向的通知在 10 分钟内只记一条，避免重复记账。
- 金额提取规则（见 `android/.../PaymentParser.kt`）：
  - 优先从 `¥/￥/RMB + 数字` 或 `数字 + 元` 中提取，支持千分位与全角符号；
  - 一条通知里出现多个数字时，取**离收支关键词最近**的那个，
    所以「余额 1000.00 元，付款成功 51.51」会记成 51.51 而不是余额；
  - 裸数字兜底只认「两位小数」，且排除日期形态（`2024.10.05` 不会被当成 2024.10）。
- 方向判定：先剥掉「微信支付 / 京东支付」这类品牌名再匹配关键词，
  避免标题里的「支付」二字把收款通知误判成支出。
  覆盖「支付成功 / 付款成功 / 支付 / 付款 / 消费 / 支出 / 扣款 / 转出 / 提现 / 交易成功」等支出词，
  以及「收款 / 到账 / 到帐 / 入账 / 存入 / 收入 / 红包 / 退款 / 收到转账」等收入词。
- 识别与真实 App 文案对齐，实测可解析：
  - 微信付款「微信支付 / 你于2026年10月20日,使用付款功能交易成功支付12.50元」
  - 微信收款「微信支付 / 微信收款 12.50元」
  - 微信转账「微信支付 / 收到转账 12.50元」「微信支付 / 转账到账 12.50元」
  - 微信提现「微信支付 / 提现到零钱 12.50元」
  - 支付宝「支付宝 / 你有一笔支出 12.50元」「支付宝 / 付款成功 12.50元」
  - 银行「招商银行 / 交易成功 12.50元」「招商银行 / 您尾号8888的储蓄卡…消费 12.50元」
  - 银行入账「工商银行 / 入账 12.50元」
  - 银联 / 抖音 / 美团等「支付成功 12.50元」
- 匹配只看**通知正文**，不绑定具体 App：任何 App 只要发出含上述关键词与金额的通知，
  都会被自动记账，`sourceApp` 记录来源包名。

> 局限：正文里既没有收支关键词、也没有金额正负号的通知（例如只有「¥12.50」）
> 会被整条忽略。方向猜错会往账本里塞一条错误的收支，漏记可以由用户手动补，
> 因此这里选择宁缺毋滥。

### 后台持续监听能力（实测）

在 Android 14 模拟器上实测：

| 场景 | 结果 |
| --- | --- |
| App 退到后台 | 持续监听 ✅ |
| App 从未被打开 | 持续监听，事件进原生缓存，下次打开自动补记 ✅ |
| 设备重启 | 系统自动重建监听服务，**不需要用户手动打开 App** ✅ |
| 被「强行停止」 | 系统同样会重新拉起监听服务 ✅（但见下方局限） |

局限：系统重新拉起监听服务需要几秒，这段时间里到达的通知会丢失。
另外部分国产 ROM（MIUI / EMUI / ColorOS 等）有额外的自启动与电池优化限制，
需要手动允许自启动、并把本 App 加入电池优化白名单。

## 持续集成

推送到 GitHub 后，`.github/workflows/build-android.yml` 与 `build-ios.yml` 会触发：
- Android（ubuntu-latest）：`flutter analyze` → `flutter test` → `:app:testDebugUnitTest`
  → `flutter build apk --release` → `remember-app-android-apk` 产物
- iOS（macos-15）：`flutter build ios --release --no-codesign` → 打包为 unsigned IPA `remember-app-unsigned-ipa`

产物在 Actions → Artifacts 中下载。生产发布时请使用自己的签名配置。

## 测试

| 层次 | 位置 | 覆盖内容 |
| --- | --- | --- |
| Dart 单元测试 | `test/` | 模型、CSV 解析、判重逻辑、事件字段映射 |
| Kotlin 单元测试 | `android/app/src/test/` | 通知解析：方向判定、金额提取（含多数字、日期、千分位等回归用例） |
| 模拟器端到端 | `tool/e2e_notification_test.py` | 真实通知 → 落库全链路、判重、离线缓存补发 |

端到端脚本需要一台已启动的 Android 模拟器：

```bash
flutter build apk --debug
adb shell cmd notification allow_listener \
    com.example.remember_app/com.example.remember_app.PaymentNotificationListenerService
python tool/e2e_notification_test.py
```

它直接查模拟器里的 sqlite，不需要肉眼看 UI；开发过程中就是它找出了
「金额取错 / 日期被当金额 / 关键词误判」三个真实缺陷。