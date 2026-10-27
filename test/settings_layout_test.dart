import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remember_app/screens/settings_screen.dart';

/// 设置页的排版回归测试。
///
/// 用户在真机上看到的状态行是这样的：
///
///   监听服务        已连  上次连接：3 小时前
///                  接
///   最近收到通知   1 小  任意通知（含聊天消息）
///                  时
///                  前
///
/// 「已连接」被压成竖着的「已连 / 接」——原因是一行里塞了
/// 标签 + 弹性空白 + 值 + 补充说明四段，补充说明一长，
/// 右边的值就只剩几像素宽。
///
/// 这个测试用同一组数据钉住修复后的排版。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('remember/payment_listener');

  /// 造一份「诊断信息最长」的数据，和用户真机上看到的一模一样。
  Map<String, dynamic> worstCaseDiagnostics() {
    final now = DateTime.now();
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
    return <String, dynamic>{
      'listenerEnabled': true,
      'serviceConnectedAt': ago(const Duration(hours: 3)),
      'lastNotificationAt': ago(const Duration(hours: 2)),
      'lastEventAt': ago(const Duration(hours: 1)),
      'lastRebindAt': ago(const Duration(minutes: 1)),
      'rebindCount': 17,
      'keepAliveArmed': true,
      'recentNotifications': <Map<String, dynamic>>[],
    };
  }

  void mockListenerChannel({bool listening = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'isListeningEnabled':
              return listening;
            case 'getDiagnostics':
              return worstCaseDiagnostics();
            default:
              return null;
          }
        });
  }

  setUp(() => mockListenerChannel());
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 用常见手机宽度铺一遍设置页。
  ///
  /// 视口拉高是为了让整页都参与布局——
  /// ListView 只构建可见区域，折叠区在屏幕外的话根本不会生成，
  /// 也就测不到里面的排版了。
  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('诊断详情展开后，最长的值也不会被挤成竖排', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('诊断详情'));
    await tester.pumpAndSettle();

    // 补充说明并进了值里，所以这两串是完整的一个值。
    expect(find.text('已连接 · 3 小时前连接'), findsOneWidget);
    expect(find.text('已开启 · 已重连 17 次'), findsOneWidget);

    // 值必须排在一行内，不能被压成「已连 / 接」这种竖排。
    for (final label in ['已连接 · 3 小时前连接', '已开启 · 已重连 17 次']) {
      final para = tester.renderObject<RenderParagraph>(find.text(label));
      final lines = para.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: label.length),
      );
      expect(lines.length, 1, reason: '「$label」被排成了 ${lines.length} 行');
    }
  });

  testWidgets('设置页不再出现那些又长又没用的说明文字', (tester) async {
    await pumpSettings(tester);

    // 这些长段落原来占掉大半屏，用户反馈过太挤太杂。
    expect(find.textContaining('如果付了钱却一直没记账'), findsNothing);
    expect(find.textContaining('任意通知（含聊天消息）'), findsNothing);
    expect(find.textContaining('Android 偶尔会在后台把监听服务解绑'), findsNothing);
  });

  testWidgets('诊断详情与通知列表默认都是收起的', (tester) async {
    await pumpSettings(tester);

    // 默认视图应该清爽：折叠区没展开。
    expect(find.text('监听服务'), findsNothing);
    expect(find.text('最近收到的通知'), findsOneWidget);

    await tester.tap(find.text('诊断详情'));
    await tester.pumpAndSettle();
    expect(find.text('监听服务'), findsOneWidget);
  });
}
