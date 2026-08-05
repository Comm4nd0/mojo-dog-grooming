import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';

/// Today's day view, which was blank every evening.
///
/// Jess: *"when looking at today on the calendar, on the day view, it doesn't
/// show anything. It's just blank. It doesn't even show the hours."* Only
/// today, only after 19:00, and only because of how a `Stack` measures itself.
///
/// `_nowLine` returned a `SizedBox.shrink()` when the time fell outside the
/// drawn window. That is a **non-positioned** child, and a `Stack` sizes to its
/// non-positioned children — `constraints.biggest` is the fallback for when it
/// has none. The width arrives loose, because a `Column` gives its children
/// loose cross-axis constraints unless told to stretch, so the Stack took the
/// 0x0 child's width and the grid painted into nothing.
///
/// The window ends at 19:00. Before then the line is inside it and the child
/// is a real `Positioned`; after it, the diary Jess was actually looking at was
/// the one blank day in the book. Every other date rendered, which is what made
/// it read as bad data rather than layout.
///
/// The clock is injected for exactly that reason: a test that can only fail
/// after seven in the evening passes all morning while the bug is still there.
void main() {
  const width = 800.0;

  /// Nested the way `calendar_screen` nests it — a `Column` with the default
  /// centre cross-alignment, which is where the loose width comes from. Using
  /// `stretch` here would hide the bug rather than test it.
  Future<void> pumpDay(WidgetTester tester, {required DateTime now}) async {
    tester.view.physicalSize = const Size(width, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 58),
            Expanded(
              child: DayTimeline(
                day: DateTime(now.year, now.month, now.day),
                appointments: const [],
                metrics: const TimelineMetrics(),
                now: now,
                onOpen: (_) {},
                onCreateAt: (_) {},
                onMove: (_, _) {},
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
  }

  Size timelineSize(WidgetTester tester) => tester
      .renderObject<RenderStack>(
        find.descendant(of: find.byType(DayTimeline), matching: find.byType(Stack)).first,
      )
      .size;

  testWidgets('an empty day after closing time still draws', (tester) async {
    // 21:00, past the 19:00 end of the window. This is the report.
    await pumpDay(tester, now: DateTime(2026, 8, 5, 21, 0));

    expect(
      timelineSize(tester).width,
      width,
      reason: 'the timeline collapsed to nothing, so the grid painted into a '
          'zero-width canvas and the day looked empty',
    );
    // 07:00 to 19:00, one label an hour.
    expect(find.textContaining(':00'), findsNWidgets(12));
    expect(find.text('07:00'), findsOneWidget);
    expect(find.text('18:00'), findsOneWidget);
  });

  testWidgets('and before opening time, which is the other end of it',
      (tester) async {
    await pumpDay(tester, now: DateTime(2026, 8, 5, 5, 30));
    expect(timelineSize(tester).width, width);
    expect(find.textContaining(':00'), findsNWidgets(12));
  });

  testWidgets('during the day it draws, and the now line with it', (tester) async {
    await pumpDay(tester, now: DateTime(2026, 8, 5, 11, 30));
    expect(timelineSize(tester).width, width);
    expect(find.textContaining(':00'), findsNWidgets(12));
  });

  testWidgets('every child of the timeline is positioned', (tester) async {
    // The rule the bug broke, stated directly: one stray non-positioned child
    // is enough to take the whole day down, and it need not be the now line.
    await pumpDay(tester, now: DateTime(2026, 8, 5, 21, 0));

    final stack = tester.renderObject<RenderStack>(
      find.descendant(of: find.byType(DayTimeline), matching: find.byType(Stack)).first,
    );
    var child = stack.firstChild;
    while (child != null) {
      final data = child.parentData! as StackParentData;
      expect(
        data.isPositioned,
        isTrue,
        reason: 'a non-positioned child makes the Stack size to it instead of '
            'to the space it was given',
      );
      child = data.nextSibling;
    }
  });
}
