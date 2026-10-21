import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:remember_app/screens/transaction_list_screen.dart';
import 'package:remember_app/screens/stats_screen.dart';
import 'package:remember_app/screens/settings_screen.dart';
import 'package:remember_app/screens/add_edit_screen.dart';
import 'package:remember_app/services/listener_diagnostics.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _index = 0;
  late AnimationController _fabAnimationController;
  late Animation<double> _fabRotation;

  /// 通知监听的诊断信息。用于在首页提示「自动记账没在工作」。
  ListenerDiagnostics? _diagnostics;

  @override
  void initState() {
    super.initState();
    _fabAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fabRotation = Tween<double>(begin: 0.0, end: 0.25 * math.pi).animate(
      CurvedAnimation(parent: _fabAnimationController, curve: Curves.easeInOut),
    );
    WidgetsBinding.instance.addObserver(this);
    _refreshDiagnostics();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fabAnimationController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 用户可能刚去系统设置开了权限，回来时刷新一下。
    if (state == AppLifecycleState.resumed) {
      _refreshDiagnostics();
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

    return Material(
      color: Colors.orange.shade50,
      child: InkWell(
        onTap: () => setState(() => _index = 2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Colors.orange.shade900),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddScreen() async {
    _fabAnimationController.forward();
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
    // await 期间 HomeScreen 可能已被销毁，此时操作 AnimationController 会抛异常。
    if (!mounted) return;
    _fabAnimationController.reset();
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
    setState(() {
      _index = index;
    });
    _fabAnimationController.reset();
  }

  @override
  Widget build(BuildContext context) {
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
          if (_buildWarningBanner() != null) _buildWarningBanner()!,
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                TransactionListScreen(),
                StatsScreen(),
                SettingsScreen(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: _onTabSelected,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt_outlined),
            activeIcon: Icon(Icons.list_alt),
            label: '账单',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined),
            activeIcon: Icon(Icons.bar_chart),
            label: '统计',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
      floatingActionButton: AnimatedBuilder(
        animation: _fabAnimationController,
        builder: (context, child) {
          return Transform.rotate(
            angle: _fabRotation.value,
            child: child,
          );
        },
        child: FloatingActionButton(
          onPressed: _showAddScreen,
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
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
