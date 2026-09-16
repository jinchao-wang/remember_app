import 'package:flutter/foundation.dart';

/// 全局数据状态：数据库变化后 notify，页面据此自动刷新。
class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  void bump() => notifyListeners();
}