import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:remember_app/screens/home_screen.dart';
import 'package:remember_app/services/listener_diagnostics.dart';
import 'package:remember_app/services/notification_listener.dart';
import 'package:remember_app/services/payment_service.dart';
import 'package:remember_app/theme/app_theme.dart';
import 'package:remember_app/utils/frame_monitor.dart';

/// 持有订阅引用，避免被 GC 回收导致自动记账中断。
StreamSubscription<PaymentEvent>? paymentSubscription;

void main() {
  // 整个启动流程都放进 zone 里：任何未捕获的异步异常都会被接住并记下来，
  // 而不是让 App 停在启动页出不来。
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    _installErrorHooks();

    // **界面先出来，初始化放后面。**
    //
    // 之前是反过来的：runApp() 排在两个 await 后面。
    // 只要初始化过程中抛了异常（数据库打不开、日期本地化数据缺失……），
    // runApp 就永远不会执行，App 会一直停在原生启动页——
    // 用户看到的正是「App 直接打不开了」，而且怎么重开都没用。
    //
    // 现在界面立刻可见：初始化失败只影响对应的那一项功能，
    // 并且失败原因会被记录下来，下次打开就能看到。
    runApp(const RememberApp());

    await _bootstrap();
  }, (error, stack) {
    _reportDartError('未捕获异常: $error\n$stack');
  });
}

/// 装上 Dart 侧的异常钩子。
///
/// release 版 Flutter 自己不打印堆栈，用户只看得到「白屏」或者「闪一下就没了」。
/// 这里把异常原样记下来，下次打开 App 时在首页和诊断详情里都能看到。
void _installErrorHooks() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _reportDartError(
      'FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
  };

  // 平台层的异步错误（未 await 的 Future 抛异常等）。
  // 返回 true 表示「我已经处理了」，别再把 App 打死。
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    _reportDartError('$error\n$stack');
    return true;
  };

  // release 版的默认错误组件是一片灰，用户完全不知道发生了什么。
  // 换成一句能看懂的话。
  ErrorWidget.builder = (details) {
    return Material(
      color: const Color(0xFFFDECEA),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '这一块没能显示出来：\n${details.exceptionAsString()}',
          style: const TextStyle(fontSize: 12, color: Color(0xFF8C1D18)),
        ),
      ),
    );
  };
}

/// 启动后的初始化。
///
/// 每一项都单独兜住：任何一项失败都不该影响已经显示出来的界面。
Future<void> _bootstrap() async {
  try {
    await initializeDateFormatting('zh_CN', null);
  } catch (e) {
    _reportDartError('日期本地化初始化失败: $e');
  }

  // 开发期掉帧监视（release 构建里是空实现）。
  FrameMonitor.start();

  try {
    // 先把设置读进来：监听服务随时可能推来第一条通知，
    // 那时候开关必须已经是用户选定的值。
    await PaymentService.loadSettings();
  } catch (e) {
    _reportDartError('读取设置失败: $e');
  }

  _startPaymentListener();
}

/// 订阅 Android 通知监听推送的支付事件，落库为自动账单。
///
/// 之前原生侧 PaymentEvents.post() 找不到 listener（EventChannel 的 onListen
/// 从未触发），导致整套自动记账功能是死代码，这里补上链路。
void _startPaymentListener() {
  // iOS / 桌面端没有对应原生实现，不订阅避免 MissingPluginException 噪音。
  if (defaultTargetPlatform != TargetPlatform.android) return;

  try {
    paymentSubscription = PaymentNotificationListener.paymentStream.listen(
      (event) {
        PaymentService.instance.handleEvent(event);
      },
      onError: (Object error) {
        debugPrint('支付通知流异常：$error');
      },
      cancelOnError: false,
    );
  } catch (e) {
    _reportDartError('订阅支付通知失败: $e');
  }
}

/// 把 Dart 侧的异常送到原生层存起来。
///
/// 原生层会写进诊断存储，用户下次打开 App 时能在首页和
/// 「设置 → 诊断详情」里看到，不用再靠「打不开了」这种描述猜原因。
void _reportDartError(String detail) {
  // 截断：堆栈可能很长，原生层要把它塞进 SharedPreferences。
  final text = detail.length > 4000
      ? '${detail.substring(0, 4000)}…'
      : detail;
  debugPrint('Dart 异常: $text');
  unawaited(ListenerDiagnosticsService.recordDartError(text));
}

class RememberApp extends StatelessWidget {
  const RememberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remember 记账',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
