import '../models/transaction.dart';
import 'app_state.dart';
import 'database.dart';
import 'notification_listener.dart';

/// 把 Android 支付通知解析结果落库为自动账单。
class PaymentService {
  static final PaymentService instance = PaymentService._();
  PaymentService._();

  /// 规则：
  /// - 10 分钟内已存在同来源 + 同金额的自动账单 -> 跳过（不重复生成）
  /// - 用户手动编辑过的记录保持原样，不会被后续通知覆盖
  /// - 其余情况新增一条自动账单
  Future<void> handleEvent(PaymentEvent event) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now();
    final window = now.subtract(const Duration(minutes: 10)).toIso8601String();

    final rows = await db.query(
      'transactions',
      where: 'isAuto = 1 AND sourceApp = ? AND date >= ?',
      whereArgs: [event.sourceApp, window],
    );
    for (final row in rows) {
      final existing = Transaction.fromMap(row);
      if ((existing.amount - event.amount).abs() < 0.005) {
        return;
      }
    }

    final tx = Transaction(
      amount: event.amount,
      type: event.type,
      category: _guessCategory(event),
      note: event.content,
      date: now,
      isAuto: true,
      isEdited: false,
      sourceApp: event.sourceApp,
    );
    await DatabaseHelper.instance.insertTransaction(tx);
    AppState.instance.bump();
  }

  String _guessCategory(PaymentEvent event) {
    final text = event.content;
    const rules = <String, List<String>>{
      '餐饮': ['美团', '饿了么', '外卖', '餐厅', '饭店', '肯德基', '麦当劳', '瑞幸', '星巴克', '奶茶', '咖啡'],
      '交通': ['滴滴', '高德', '打车', '出租', '加油', '充电', '停车', '地铁', '公交', '12306', '铁路'],
      '购物': ['淘宝', '天猫', '京东', '拼多多', '抖音', '快手', '商城', '购物', '快递', '下单'],
      '日用': ['超市', '便利店', '水果', '买菜', '永辉', '大润发', '沃尔玛'],
      '娱乐': ['电影', '游戏', '视频', '音乐', '会员', '充值', '直播'],
      '转账': ['微信', '支付宝', '转账', '红包', '还款', '收款', '到账', '银行'],
    };
    for (final entry in rules.entries) {
      if (entry.value.any(text.contains)) return entry.key;
    }
    return '其他';
  }
}