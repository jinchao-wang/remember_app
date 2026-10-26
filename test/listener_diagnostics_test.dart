import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/services/listener_diagnostics.dart';

void main() {
  group('监听诊断快照', () {
    test('空快照的默认值是安全的', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{});

      expect(d.listenerEnabled, isFalse);
      expect(d.serviceConnectedAt, isNull);
      expect(d.serviceDisconnectedAt, isNull);
      expect(d.lastNotificationAt, isNull);
      expect(d.recentNotifications, isEmpty);
      expect(d.serviceEverConnected, isFalse);
      expect(d.serviceLooksConnected, isFalse);
    });

    test('连上过就认为服务曾经活着', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
      });

      expect(d.serviceEverConnected, isTrue);
      expect(d.serviceLooksConnected, isTrue);
    });

    test('断开时间晚于连接时间说明服务当前是断的', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'serviceDisconnectedAt': 2000,
      });

      expect(d.serviceEverConnected, isTrue);
      expect(d.serviceLooksConnected, isFalse);
    });

    test('重新连上之后又算活着', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 3000,
        'serviceDisconnectedAt': 2000,
      });

      expect(d.serviceLooksConnected, isTrue);
    });

    test('时间戳为 0 视为没有记录', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'serviceConnectedAt': 0,
        'lastNotificationAt': 0,
      });

      expect(d.serviceConnectedAt, isNull);
      expect(d.lastNotificationAt, isNull);
    });

    test('通知记录能解析出来，并保留未记账的原因', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'lastNotificationAt': 2000,
        'recentNotifications': [
          {
            'packageName': 'com.tencent.mm',
            'title': '微信支付',
            'text': '你于2026年10月20日,使用付款功能交易成功支付31.31元',
            'recognized': true,
            'reason': '已识别：expense 31.31',
            'timestamp': 2000,
          },
          {
            'packageName': 'com.tencent.mm',
            'title': '微信支付',
            'text': '¥12.34',
            'recognized': false,
            'reason': '没有收支关键词，也没有金额正负号',
            'timestamp': 3000,
          },
        ],
      });

      expect(d.recentNotifications.length, 2);
      expect(d.recentNotifications.first.recognized, isTrue);
      expect(d.recentNotifications.first.title, '微信支付');
      expect(d.recentNotifications.last.recognized, isFalse);
      expect(d.recentNotifications.last.reason, '没有收支关键词，也没有金额正负号');
    });

    test('通知正文为空时用标题兜底', () {
      final r = NotificationRecord.fromMap(<String, dynamic>{
        'packageName': 'com.tencent.mm',
        'title': '微信支付',
        'text': '',
        'recognized': false,
        'reason': '通知正文为空',
        'timestamp': 1,
      });

      expect(r.summary, '微信支付');
    });

    test('标题正文都为空时给出占位文案', () {
      final r = NotificationRecord.fromMap(<String, dynamic>{'timestamp': 1});
      expect(r.summary, '(空通知)');
    });
  });

  group('通知记录的金额与补记', () {
    NotificationRecord build(Map<String, dynamic> extra) =>
        NotificationRecord.fromMap(<String, dynamic>{
          'packageName': 'com.tencent.mm',
          'title': '微信支付',
          'text': '¥31.31',
          'recognized': false,
          'reason': '没有收支关键词，也没有金额正负号',
          'timestamp': 1000,
          ...extra,
        });

    test('能读出金额且没记账 -> 可以手动补记', () {
      final r = build({'amount': 31.31});

      expect(r.amount, 31.31);
      expect(r.recorded, isFalse);
      expect(r.canManuallyRecord, isTrue);
    });

    test('已经自动记账的 -> 不给补记入口', () {
      final r = build({'amount': 31.31, 'recognized': true});

      expect(r.canManuallyRecord, isFalse);
    });

    test('已经手动补记过的 -> 不给补记入口', () {
      final r = build({'amount': 31.31, 'recorded': true});

      expect(r.canManuallyRecord, isFalse);
    });

    test('读不出金额的 -> 不给补记入口', () {
      final r = build({'reason': '通知正文为空', 'text': ''});

      expect(r.amount, isNull);
      expect(r.canManuallyRecord, isFalse);
    });

    test('金额为 0 的 -> 不给补记入口', () {
      final r = build({'amount': 0.0});
      expect(r.canManuallyRecord, isFalse);
    });

    test('标题和正文拼起来就是通知原文', () {
      final r = build({'text': '收款到账 ¥66.60'});
      expect(r.fullText, '微信支付 收款到账 ¥66.60');
    });

    test('只有标题时原文就是标题', () {
      final r = build({'text': ''});
      expect(r.fullText, '微信支付');
    });
  });

  group('保活与重连状态', () {
    test('解析保活相关字段', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'lastRebindAt': 2000,
        'rebindCount': 7,
        'lastRebindOk': true,
        'keepAliveArmed': true,
      });

      expect(d.lastRebindAt, isNotNull);
      expect(d.lastRebindAt!.millisecondsSinceEpoch, 2000);
      expect(d.rebindCount, 7);
      expect(d.lastRebindOk, isTrue);
      expect(d.keepAliveArmed, isTrue);
    });

    test('缺省值是安全的', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{});

      expect(d.lastRebindAt, isNull);
      expect(d.rebindCount, 0);
      expect(d.lastRebindOk, isFalse);
      expect(d.keepAliveArmed, isFalse);
    });

    test('重连次数为 0 时不显示成「已重连 0 次」', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{});
      expect(d.rebindCount > 0, isFalse);
    });
  });

  group('绑定是否还活着', () {
    test('解析最近一次收到任意通知的时间', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'lastEventAt': 2000,
      });

      expect(d.lastEventAt, isNotNull);
      expect(d.lastEventAt!.millisecondsSinceEpoch, 2000);
    });

    test('没收到过任何通知 -> 不算活着', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
      });

      expect(d.lastEventAt, isNull);
      expect(d.listenerLooksAlive, isFalse);
      expect(d.listenerLooksStuck, isTrue);
    });

    test('刚收到过通知 -> 算活着', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'lastEventAt':
            DateTime.now().millisecondsSinceEpoch - 60 * 1000,
      });

      expect(d.listenerLooksAlive, isTrue);
      expect(d.listenerLooksStuck, isFalse);
    });

    test('很久没收到任何通知 -> 判定为绑定僵死', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'lastEventAt':
            DateTime.now().millisecondsSinceEpoch - 3 * 60 * 60 * 1000,
      });

      // 系统那边说「已连接」，但实际早就收不到通知了——这正是用户报的故障。
      expect(d.serviceLooksConnected, isTrue);
      expect(d.listenerLooksAlive, isFalse);
      expect(d.listenerLooksStuck, isTrue);
    });

    test('系统已经断开时不重复报僵死', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'listenerEnabled': true,
        'serviceConnectedAt': 1000,
        'serviceDisconnectedAt': 2000,
      });

      expect(d.serviceLooksConnected, isFalse);
      expect(d.listenerLooksStuck, isFalse);
    });
  });

  group('重连结果', () {
    test('解析上次重连的结果', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{
        'lastReconnectAt': 5000,
        'lastReconnectOk': true,
        'lastReconnectStage': 'rebind',
        'lastReconnectMessage': '监听服务还活着，已重新请求连接',
      });

      expect(d.lastReconnectAt, isNotNull);
      expect(d.lastReconnectAt!.millisecondsSinceEpoch, 5000);
      expect(d.lastReconnectOk, isTrue);
      expect(d.lastReconnectStage, 'rebind');
      expect(d.lastReconnectMessage, '监听服务还活着，已重新请求连接');
    });

    test('缺省值是安全的', () {
      final d = ListenerDiagnostics.fromMap(<String, dynamic>{});

      expect(d.lastReconnectAt, isNull);
      expect(d.lastReconnectOk, isFalse);
      expect(d.lastReconnectStage, '');
      expect(d.lastReconnectMessage, '');
    });
  });
}
