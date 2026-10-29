import 'package:flutter_test/flutter_test.dart';
import 'package:remember_app/services/database.dart';

/// 设置项的布尔解析。
///
/// 这一组测试守的是一个已经出过事的回归：
/// 存的时候写的是字符串 '1' / '0'，读的时候却只认 'true' / 'false'，
/// 于是用户把「跨来源自动去重」打开（存 '1'），重启 App 读回来是 false，
/// 开关自己变回关闭——重复账单的问题于是「修了跟没修一样」。
void main() {
  group('设置项布尔解析', () {
    test('认得自己写进去的 1 / 0', () {
      expect(DatabaseHelper.parseBoolSetting('1', defaultValue: false), isTrue);
      expect(DatabaseHelper.parseBoolSetting('0', defaultValue: true), isFalse);
    });

    test('也认得 true / false（兼容老数据）', () {
      expect(DatabaseHelper.parseBoolSetting('true', defaultValue: false), isTrue);
      expect(DatabaseHelper.parseBoolSetting('false', defaultValue: true), isFalse);
    });

    test('大小写和空格都不影响', () {
      expect(DatabaseHelper.parseBoolSetting('TRUE', defaultValue: false), isTrue);
      expect(DatabaseHelper.parseBoolSetting(' True ', defaultValue: false), isTrue);
    });

    test('原生 bool 与数字也能认', () {
      expect(DatabaseHelper.parseBoolSetting(true, defaultValue: false), isTrue);
      expect(DatabaseHelper.parseBoolSetting(false, defaultValue: true), isFalse);
      expect(DatabaseHelper.parseBoolSetting(1, defaultValue: false), isTrue);
      expect(DatabaseHelper.parseBoolSetting(0, defaultValue: true), isFalse);
    });

    test('空值退回默认值', () {
      expect(DatabaseHelper.parseBoolSetting(null, defaultValue: true), isTrue);
      expect(DatabaseHelper.parseBoolSetting('', defaultValue: true), isTrue);
      expect(DatabaseHelper.parseBoolSetting(null, defaultValue: false), isFalse);
    });

    test('认不出来的值退回默认值，绝不瞎猜', () {
      expect(DatabaseHelper.parseBoolSetting('maybe', defaultValue: true), isTrue);
      expect(DatabaseHelper.parseBoolSetting('maybe', defaultValue: false), isFalse);
    });
  });
}
