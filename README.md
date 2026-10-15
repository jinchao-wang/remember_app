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
- 金额优先从 `¥/￥/RMB + 数字` 或 `数字 + 元` 中提取；否则退化为「两位小数」兜底，
  因此纯订单号、卡号不会被误判为金额。

> 局限：Android 会在应用被「强行停止」后停止重启服务，此时不再监听；
> 正常的划掉后台则不影响，系统会重新拉起服务并继续缓存。

## 持续集成

推送到 GitHub 后，`.github/workflows/build-android.yml` 与 `build-ios.yml` 会触发：
- Android（ubuntu-latest）：`flutter build apk --release` → `remember-app-android-apk` 产物
- iOS（macos-15）：`flutter build ios --release --no-codesign` → 打包为 unsigned IPA `remember-app-unsigned-ipa`

产物在 Actions → Artifacts 中下载。生产发布时请使用自己的签名配置。