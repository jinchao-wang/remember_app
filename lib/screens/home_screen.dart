import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remember_app/screens/transaction_list_screen.dart';
import 'package:remember_app/screens/stats_screen.dart';
import 'package:remember_app/screens/settings_screen.dart';
import 'package:remember_app/screens/add_edit_screen.dart';
import 'package:remember_app/services/listener_diagnostics.dart';
import 'package:remember_app/theme/app_theme.dart';
import 'package:remember_app/utils/frame_monitor.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _index = 0;

  /// 通知监听的诊断信息。用于在首页提示「自动记账没在工作」。
  ListenerDiagnostics? _diagnostics;

  /// 用来在切到「设置」页签时让设置页自己刷新一次诊断。
  final GlobalKey<SettingsScreenState> _settingsKey =
      GlobalKey<SettingsScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshDiagnostics();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户可能刚去系统设置开了权限，回来时刷新一下。
    if (state == AppLifecycleState.resumed) {
      _refreshDiagnostics();
    }
    // 退到后台时把这次的帧统计打出来，方便开发期量性能。
    if (state == AppLifecycleState.paused) {
      FrameMonitor.report();
    }
  }

  Future<void> _refreshDiagnostics() async {
    final diag = await ListenerDiagnosticsService.fetch();
    if (!mounted) return;
    setState(() => _diagnostics = diag);
  }

  /// 首页顶部的告警条。
  ///
  /// 「通知监听已开启」这种状态藏在设置页里，用户不会去看。
  /// 自动记账没工作却没有任何提示，是「有通知但没记账」这类问题的根源之一。
  Widget? _buildWarningBanner() {
    final diag = _diagnostics;
    if (diag == null) return null;

    // 上次崩溃优先展示。
    //
    // 用户报「App 打不开」时，这一行就是最直接的线索。
    // 它必须出现在**首页**——因为「打不开」往往意味着用户压根进不到设置页，
    // 藏在设置页里的信息等于没有。
    if (diag.lastCrash.isNotEmpty) {
      // 原生崩溃和 Dart 异常都记在这里，但说法不一样：
      // 说「崩溃了」而实际只是读数据失败，会让用户以为 App 闪退过。
      final isDart = diag.lastCrash.trimLeft().startsWith('Dart:');
      return _warningBar(
        '${isDart ? '上次运行出错了' : '上次运行崩溃了'}：'
        '${_firstLine(diag.lastCrash)}，点此查看详情',
        Icons.bug_report,
      );
    }

    final String message;
    final IconData icon;
    if (!diag.listenerEnabled) {
      message = '自动记账未开启：支付通知不会被记录，去「设置 → 自动记账」开启通知使用权';
      icon = Icons.warning_amber;
    } else if (!diag.serviceEverConnected) {
      message = '自动记账未生效：已授权但系统还没拉起监听服务，去「设置 → 自动记账」查看排查指引';
      icon = Icons.error_outline;
    } else {
      return null;
    }

    return _warningBar(message, icon);
  }

  /// 崩溃摘要只取第一行：完整堆栈在告警条里放不下，
  /// 完整内容在设置页的诊断详情里。
  String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }

  Widget _warningBar(String message, IconData icon) {
    return Material(
      color: context.scheme.errorContainer,
      child: InkWell(
        onTap: () => setState(() => _index = 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: context.scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.scheme.onErrorContainer,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: context.scheme.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddScreen() async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => const AddEditScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          );
        },
      ),
    );
  }

  Future<void> _showDatePicker() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (date == null || !mounted) return;

    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            TransactionListScreen(selectedDate: date),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          );
        },
      ),
    );
  }

  void _onTabSelected(int index) {
    if (index == _index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _index = index;
    });
    // 切到设置页时重新拉一次诊断。
    //
    // 设置页在 IndexedStack 里一直活着，它显示的是「上次打开时的快照」。
    // 用户付完钱切过来却看到「还没有收到疑似支付类的通知」，
    // 就会误以为系统没把通知送过来——这正是「有通知但没记账」的错觉来源。
    if (index == 2) {
      _settingsKey.currentState?.refreshDiagnostics();
      _refreshDiagnostics();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 先取一次，避免同一个告警条被构建两遍。
    final banner = _buildWarningBanner();
    return Scaffold(
      appBar: AppBar(
        title: Text(_getCurrentTitle()),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: _showDatePicker,
          ),
        ],
      ),
      body: Column(
        children: [
          if (banner != null) banner,
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                const TransactionListScreen(),
                const StatsScreen(),
                SettingsScreen(key: _settingsKey),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onTabSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: '账单',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: '统计',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
      // 「记一笔」只在账单页出现。
      // 统计页和设置页用不到它，悬浮在右下角反而挡住图表和内容。
      floatingActionButton: _index == 0
          ? TweenAnimationBuilder<double>(
              // key 跟着页签走：从别的页切回账单页时按钮会重新弹一下，
              // 告诉用户「它回来了」。
              key: ValueKey(_index),
              tween: Tween<double>(begin: 0.75, end: 1),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutBack,
              builder: (context, value, child) =>
                  Transform.scale(scale: value, child: child),
              child: FloatingActionButton(
                onPressed: _showAddScreen,
                tooltip: '记一笔',
                child: const Icon(Icons.add),
              ),
            )
          : null,
    );
  }

  String _getCurrentTitle() {
    return switch (_index) {
      0 => '我的账单',
      1 => '数据统计',
      2 => '设置',
      _ => '记账本',
    };
  }
}
