import 'package:flutter/material.dart';
import '../services/notification_listener.dart';
import '../services/payment_service.dart';
import 'add_edit_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'transaction_list_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _initListener();
  }

  Future<void> _initListener() async {
    final ok = await PaymentNotificationListener.startListening();
    if (!mounted) return;
    setState(() => _listening = ok);
    if (ok) {
      PaymentNotificationListener.paymentStream.listen(PaymentService.instance.handleEvent);
    }
  }

  Future<void> _openAdd() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddEditScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remember 记账'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(_listening ? Icons.notifications_active : Icons.notifications_off, color: _listening ? Colors.green : Colors.grey),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          TransactionListScreen(),
          StatsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: '账单'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: '统计'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '设置'),
        ],
      ),
      floatingActionButton: _index == 0 ? FloatingActionButton(onPressed: _openAdd, child: const Icon(Icons.add)) : null,
    );
  }
}