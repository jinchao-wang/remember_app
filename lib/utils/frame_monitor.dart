import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 开发期的掉帧监视器（只在 debug 模式生效）。
///
/// Flutter 用自己的引擎渲染，Android 的 `dumpsys gfxinfo` 统计的是 HWUI 的帧，
/// **统计不到 Flutter 画的帧**——所以要量「掉不掉帧」只能自己挂
/// [SchedulerBinding.addTimingsCallback]。
///
/// 用法：App 启动时调一次 [start]，然后
/// `adb logcat -s flutter` 就能看到所有超过 16ms 的帧。
///
/// 这个文件是开发工具，不参与 release 构建。
class FrameMonitor {
  static bool _started = false;

  /// 一个帧超过 16ms 就算掉帧（60Hz）。
  static const int frameBudgetMs = 16;

  static int dropped = 0;
  static int total = 0;

  /// 每一帧的耗时（毫秒），用来算中位数 / P90。
  static final List<double> durations = <double>[];

  /// 每一帧的**构建**耗时（毫秒）。
  static final List<double> builds = <double>[];

  /// 最慢的一帧。
  static double worstMs = 0;

  static void start() {
    if (!kDebugMode || _started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        total++;
        final ms = t.totalSpan.inMicroseconds / 1000;
        durations.add(ms);
        // build 是 Flutter 构建 widget 树的时间——
        // 这才是「列表用不用一次性全建」影响到的部分。
        // total 还包含光栅化，模拟器上是软件渲染，那部分跟代码无关。
        final build = t.buildDuration.inMicroseconds / 1000;
        builds.add(build);
        if (ms > frameBudgetMs) dropped++;
        if (ms > worstMs) worstMs = ms;
      }
    });
  }

  /// 打印一份汇总，方便脚本读取。
  ///
  /// 只看「掉帧率」不够用——软件渲染的模拟器上每一帧都超预算，
  /// 有区分度的是**构建耗时**：一次性构建 600 行和只构建屏幕内那十几行，
  /// 差距全在这一个数上。
  ///
  /// 注意不要逐帧打印：debugPrint 是限流的，几百条日志会把汇总行
  /// 堵在队列最后面迟迟出不来。
  static void report() {
    if (!kDebugMode) return;
    if (durations.isEmpty) {
      debugPrint('[FrameMonitor] 汇总：没有数据');
      return;
    }
    final sorted = List<double>.from(durations)..sort();
    final sortedBuild = List<double>.from(builds)..sort();
    double at(List<double> s, double q) =>
        s[(s.length * q).clamp(0, s.length - 1).round()];
    debugPrint('[FrameMonitor] 汇总：共 $total 帧，'
        '构建 中位 ${at(sortedBuild, 0.5).toStringAsFixed(1)}ms/'
        'P90 ${at(sortedBuild, 0.9).toStringAsFixed(1)}ms/'
        '最慢 ${at(sortedBuild, 1.0).toStringAsFixed(1)}ms，'
        '帧时长 中位 ${at(sorted, 0.5).toStringAsFixed(1)}ms/'
        'P90 ${at(sorted, 0.9).toStringAsFixed(1)}ms/'
        '最慢 ${worstMs.toStringAsFixed(1)}ms');
  }
}
