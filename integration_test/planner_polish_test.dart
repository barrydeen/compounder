import 'package:compounder/data/store.dart';
import 'package:compounder/main.dart' as app;
import 'package:compounder/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Emulator proof for the planner day-view polish: a centered "Now" label
/// scoped to the block column, 12-hour am/pm time labels, and a visible gap
/// between two back-to-back blocks. The screenshot is taken by the operator
/// (adb exec-out screencap) while this test holds the planner open — the
/// PLANNER_POLISH_READY marker is the sync point.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'planner polish: centered now marker, am/pm labels, back-to-back gap',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cleaner = await AppStore.open(prefs);
    // Deterministic slate: wipe the day's blocks, then seed two touching
    // 30-minute blocks straddling "now" so the marker renders between cards.
    await cleaner.db.delete('plan_blocks');
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    int start;
    int mid;
    int finish;
    if (nowMin < 15) {
      start = 0;
      mid = 30;
      finish = 60;
    } else if (nowMin > 1425) {
      start = 1380;
      mid = 1410;
      finish = 1439;
    } else {
      start = nowMin - 10;
      mid = nowMin + 20;
      finish = nowMin + 50;
    }
    await cleaner.createPlanBlock(
        day: now, title: 'Morning focus', startMin: start, endMin: mid);
    await cleaner.createPlanBlock(
        day: now, title: 'Gym session', startMin: mid, endMin: finish);

    app.bootstrapForTest();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The app owns the store; assert on the instance the UI writes to.
    final store = Provider.of<AppStore>(
        tester.element(find.byType(ShellScreen)),
        listen: false);

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Day planner')));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The now marker renders with an am/pm suffix in the label.
    final nowLabel = find.textContaining('Now ');
    expect(nowLabel, findsOneWidget);
    expect(find.textContaining(' AM'), findsWidgets,
        reason: 'hour labels and card times render in 12-hour am/pm');
    expect(find.text('Morning focus'), findsOneWidget);
    expect(find.text('Gym session'), findsOneWidget);

    // The now label is horizontally centered within the block column:
    // 56dp hour-label gutter on the left, 8dp inset on the right.
    final labelRect = tester.getRect(nowLabel);
    final gridRect = tester.getRect(find.byKey(const Key('plan-grid')));
    final columnLeft = gridRect.left + 56;
    final columnRight = gridRect.right - 8;
    final columnCenter = (columnLeft + columnRight) / 2;
    expect(labelRect.left, greaterThanOrEqualTo(columnLeft),
        reason: 'the label starts inside the block column');
    expect(labelRect.right, lessThanOrEqualTo(columnRight),
        reason: 'the label ends inside the block column');
    expect((labelRect.center.dx - columnCenter).abs(), lessThanOrEqualTo(1.0),
        reason: 'the now label must sit dead center over the block column');

    // Both seeded blocks are on today's plan.
    final seeded = await store.planBlocksForDay(now);
    expect(seeded.length, 2);

    // Hold the planner on screen for the operator's screencap.
    debugPrint('PLANNER_POLISH_READY');
    await Future<void>.delayed(const Duration(seconds: 30));
  });
}
