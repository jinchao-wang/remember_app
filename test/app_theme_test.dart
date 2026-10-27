import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remember_app/theme/app_theme.dart';

/// 主题层的回归测试。
///
/// 这一轮把「支出是红的、收入是绿的」从写死的 `Colors.red` / `Colors.green`
/// 收进了 [AppColors]。原因很实际：红绿本身在深色背景上就很难区分，
/// 而且 `Colors.red` 在暗底上会刺眼到看不清数字。
///
/// 这个测试把两件事钉住：
/// - 明暗两套语义色确实不同，深色下不是原始红绿；
/// - 分类色在深色下会被提亮（用户靠颜色认分类，糊了就没意义了）。
void main() {
  group('AppColors', () {
    test('明暗两套语义色不同，深色下不是原始红绿', () {
      final light = buildAppTheme(brightness: Brightness.light)
          .extension<AppColors>()!;
      final dark =
          buildAppTheme(brightness: Brightness.dark).extension<AppColors>()!;

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);

      expect(light.expense, isNot(dark.expense));
      expect(light.income, isNot(dark.income));

      // 重点：深色下不能再是刺眼的纯红绿。
      expect(dark.expense, isNot(Colors.red));
      expect(dark.income, isNot(Colors.green));
      expect(dark.expense, isNot(Colors.green));
      expect(dark.income, isNot(Colors.red));
    });

    test('浅色容器在深色下应该是暗的，否则底色会突兀', () {
      final light = buildAppTheme(brightness: Brightness.light)
          .extension<AppColors>()!;
      final dark =
          buildAppTheme(brightness: Brightness.dark).extension<AppColors>()!;

      expect(
        light.expenseContainer.computeLuminance(),
        greaterThan(dark.expenseContainer.computeLuminance()),
      );
      expect(
        light.incomeContainer.computeLuminance(),
        greaterThan(dark.incomeContainer.computeLuminance()),
      );
    });

    test('copyWith / lerp 能正确合并与插值', () {
      const base = AppColors(
        brightness: Brightness.light,
        expense: Color(0xFF111111),
        income: Color(0xFF222222),
        expenseContainer: Color(0xFF333333),
        incomeContainer: Color(0xFF444444),
        neutralContainer: Color(0xFF555555),
      );

      final copied = base.copyWith(expense: const Color(0xFFAAAAAA));
      expect(copied.expense, const Color(0xFFAAAAAA));
      expect(copied.income, base.income);

      final other = base.copyWith(expense: const Color(0xFFFFFFFF));
      final mid = base.lerp(other, 0.5);
      expect(mid.expense, isNot(base.expense));
      expect(mid.expense, isNot(other.expense));
    });
  });

  group('分类色', () {
    test('浅色模式保持原色，用户认分类的颜色表不变', () {
      final light = buildAppTheme(brightness: Brightness.light)
          .extension<AppColors>()!;
      const base = Color(0xFF4CAF50);
      expect(light.categoryColor(base), base);
    });

    test('深色模式自动提亮，分类色在黑底上不会糊', () {
      final dark =
          buildAppTheme(brightness: Brightness.dark).extension<AppColors>()!;
      const base = Color(0xFF4CAF50);

      final brightened = dark.categoryColor(base);
      expect(brightened, isNot(base));

      final before = HSLColor.fromColor(base).lightness;
      final after = HSLColor.fromColor(brightened).lightness;
      expect(after, greaterThan(before));

      // 提亮后整体更亮（可读性更强）。
      expect(
        brightened.computeLuminance(),
        greaterThan(base.computeLuminance()),
      );
    });
  });

  group('BuildContext 扩展', () {
    testWidgets('挂着 App 主题时能取到语义色', (tester) async {
      late AppColors seen;
      late Color incomeColor;
      late Color expenseColor;
      late Color containerForExpense;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              seen = context.appColors;
              incomeColor = context.moneyColor('income');
              expenseColor = context.moneyColor('expense');
              containerForExpense = context.moneyContainer('expense');
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(seen.brightness, Brightness.dark);
      expect(incomeColor, seen.income);
      expect(expenseColor, seen.expense);
      expect(containerForExpense, seen.expenseContainer);
    });

    testWidgets('没挂 App 主题时退回默认配色，不会崩', (tester) async {
      late AppColors seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = context.appColors;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(seen.brightness, Brightness.light);
      expect(seen.expense, isNotNull);
    });
  });
}
