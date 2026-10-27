import 'dart:async';

// material.dart 只通过 widgets.dart 的 show 列表再导出 foundation 的一部分，
// defaultTargetPlatform / TargetPlatform 不在其中，必须显式导入。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:remember_app/screens/home_screen.dart';
import 'package:remember_app/services/notification_listener.dart';
import 'package:remember_app/services/payment_service.dart';
import 'package:remember_app/theme/app_theme.dart';
import 'package:remember_app/utils/frame_monitor.dart';

/// 持有订阅引用，避免被 GC 回收导致自动记账中断。
StreamSubscription<PaymentEvent>? paymentSubscription;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('zh_CN', null);
  // 开发期掉帧监视（release 构建里是空实现）。
  FrameMonitor.start();
  // 先把设置读进来：监听服务随时可能推来第一条通知，
  // 那时候开关必须已经是用户选定的值。
  await PaymentService.loadSettings();
  _startPaymentListener();
  runApp(const RememberApp());
}

/// 订阅 Android 通知监听推送的支付事件，落库为自动账单。
///
/// 之前原生侧 PaymentEvents.post() 找不到 listener（EventChannel 的 onListen
/// 从未触发），导致整套自动记账功能是死代码，这里补上链路。
void _startPaymentListener() {
  // iOS / 桌面端没有对应原生实现，不订阅避免 MissingPluginException 噪音。
  if (defaultTargetPlatform != TargetPlatform.android) return;

  paymentSubscription = PaymentNotificationListener.paymentStream.listen(
    (event) {
      PaymentService.instance.handleEvent(event);
    },
    onError: (Object error) {
      debugPrint('支付通知流异常：$error');
    },
    cancelOnError: false,
  );
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