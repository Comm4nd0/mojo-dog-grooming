/// Diagnostic only — prints geometry, asserts almost nothing.
///
/// `calendar_drag_test.dart` is green on Windows and red on Xcode Cloud's macOS
/// runners, and two attempts at fixing it from the failure log alone were both
/// wrong: a route-transition race (the AbsorbPointer/IgnorePointer entries in
/// the hit chain turned out to be proxy boxes passing pointers through, not
/// evidence of a transition), then viewport clipping (reproducible locally, and
/// it produces the identical signature — but the failing block sits at y=252,
/// which is inside the surface either way).
///
/// What is actually known: at the block's own centre, the hit test returns a
/// chain containing no part of the DayTimeline subtree at all — no viewport, no
/// Stack, no gesture detector — just a Material and then route-level widgets.
/// So on that machine the timeline is not where it says it is, and nothing in
/// the log says why.
///
/// This prints the numbers needed to tell which of those is true. Delete it
/// once the drag tests are reliably green.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/models/models.dart';
import 'package:mojo_app/widgets/calendar/appointment_block.dart';
import 'package:mojo_app/widgets/calendar/day_timeline.dart';
import 'package:mojo_app/widgets/calendar/timeline_layout.dart';
import 'package:mojo_app/widgets/calendar/timeline_metrics.dart';

void main() {
  Future<void> probe(WidgetTester tester, String label, double? bodyHeight) async {
    final appointment = Appointment(
      id: 1, dogId: 7, dogName: 'Biscuit', clientId: 1,
      clientName: 'Alice Adams', clientPhone: '07700900001',
      startAt: DateTime(2026, 8, 3, 10, 0),
      endAt: DateTime(2026, 8, 3, 11, 0),
      durationMinutes: 60, bookingType: 'ADHOC',
      serviceType: ServiceType.groom, status: 'BOOKED', notes: '',
    );

    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final timeline = DayTimeline(
      day: DateTime(2026, 8, 3),
      appointments: [appointment],
      metrics: const TimelineMetrics(),
      onOpen: (_) {},
      onCreateAt: (_) {},
      onMove: (_, _) {},
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: bodyHeight == null
            ? timeline
            : SizedBox(height: bodyHeight, child: timeline),
      ),
    ));
    await tester.pumpAndSettle();

    final view = tester.view;
    debugPrint('');
    debugPrint('===== PROBE [$label] =====');
    debugPrint('view.physicalSize   = ${view.physicalSize}  dpr=${view.devicePixelRatio}');
    debugPrint('logical surface     = '
        '${view.physicalSize.width / view.devicePixelRatio} x '
        '${view.physicalSize.height / view.devicePixelRatio}');
    debugPrint('textScaler          = ${tester.platformDispatcher.textScaleFactor}');
    debugPrint('content height      = '
        '${dayWindowFor([appointment]).height(const TimelineMetrics())}');

    for (final e in {
      'Scaffold': find.byType(Scaffold),
      'DayTimeline': find.byType(DayTimeline),
      'AppointmentBlock': find.byType(AppointmentBlock),
    }.entries) {
      if (e.value.evaluate().isEmpty) {
        debugPrint('${e.key}: NOT FOUND');
      } else {
        debugPrint('${e.key}: ${tester.getRect(e.value)}');
      }
    }

    final centre = tester.getCenter(find.byType(AppointmentBlock));
    final result = HitTestResult();
    RendererBinding.instance.renderViews.first
        .hitTest(BoxHitTestResult.wrap(result), position: centre);

    var reachedBlock = false;
    debugPrint('hit chain at block centre $centre:');
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderBox) {
        debugPrint('  ${t.runtimeType} size=${t.size}');
        if (t.runtimeType.toString() == 'RenderOpacity' && t.size.height == 72) {
          reachedBlock = true;
        }
      } else {
        debugPrint('  ${t.runtimeType}');
      }
    }
    debugPrint('BLOCK REACHED: $reachedBlock   <-- false means this is the bug');
    debugPrint('===== end [$label] =====');
  }

  testWidgets('PROBE scaffold body unconstrained (original)',
      (t) => probe(t, 'unconstrained', null));
  testWidgets('PROBE body 900 (taller than content)',
      (t) => probe(t, 'body-900', 900));
  testWidgets('PROBE body 500 (scrollable)',
      (t) => probe(t, 'body-500', 500));
}
