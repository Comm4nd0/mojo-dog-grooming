import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mojo_app/constants/app_colors.dart';
import 'package:mojo_app/services/groom_timer_service.dart';
import 'package:mojo_app/services/service_locator.dart';
import 'package:mojo_app/screens/staff/staff_shell.dart';

/// The running-timer bar that sits above the staff tabs.
///
/// It exists because the timer now outlives its screen: something has to say
/// so, or a timer left running is invisible until the next groom inherits it.
///
/// The layout half is not incidental. `_bookBar` on the dog profile once used
/// an `Align` with no `heightFactor` and ate the whole screen, so a second
/// widget going into a `bottomNavigationBar` gets checked rather than assumed.
void main() {
  tearDown(getIt.reset);

  Future<GroomTimerService> pumpBar(WidgetTester tester) async {
    // Constructed and left alone. The constructor kicks off a restore against
    // a keystore that is not there under test, and **it must not be awaited**:
    // `testWidgets` runs inside `FakeAsync`, so a platform-channel reply never
    // arrives unless the clock is pumped, and awaiting it here deadlocks the
    // test outright. The service swallows the failure and starts empty, which
    // is the state these are about.
    final timer = GroomTimerService();
    getIt.registerSingleton<GroomTimerService>(timer);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.lightTheme(),
      home: const Scaffold(
        body: Center(child: Text('a screen')),
        bottomNavigationBar: GroomTimerBar(),
      ),
    ));
    return timer;
  }

  testWidgets('takes no room at all when nothing is being timed', (tester) async {
    await pumpBar(tester);
    await tester.pump();

    expect(find.byType(InkWell), findsNothing);
    // No height at all, not a thin empty bar: the tabs must not shuffle up
    // for a timer that is not running. The width comes from the incoming
    // constraints and says nothing either way.
    expect(tester.getSize(find.byType(GroomTimerBar)).height, 0);
  });

  testWidgets('names the dog and the phase once one is running', (tester) async {
    final timer = await pumpBar(tester);
    timer.openFor(dogId: 1, dogName: 'Bunny');
    timer.toggle('CLIP');
    await tester.pump();

    expect(find.textContaining('Bunny'), findsOneWidget);
    expect(find.textContaining('Clip'), findsOneWidget);

    // And it is a strip along the bottom, not something that has expanded to
    // fill whatever it was given.
    final size = tester.getSize(find.byType(GroomTimerBar));
    expect(size.height, lessThan(80));
    expect(size.width, tester.getSize(find.byType(MaterialApp)).width);

    // The ticker is a real `Timer.periodic` and outlives the widget tree by
    // design — that is the point of the service. `testWidgets` checks for
    // pending timers *before* teardowns run, so it has to be stopped here.
    timer.pause();
  });

  testWidgets('a pause reads as paused, not as finished', (tester) async {
    final timer = await pumpBar(tester);
    timer.openFor(dogId: 1, dogName: 'Bunny');
    // Banked time first. A phase started and stopped inside a test clock that
    // never moves banks nothing, and a nil session is correctly not shown.
    timer.setMinutes('PREP', 8);
    timer.toggle('CLIP');
    await tester.pump();
    expect(find.textContaining('Clip'), findsOneWidget);

    timer.pause();
    await tester.pump();
    expect(find.textContaining('paused'), findsOneWidget);
  });

  testWidgets('a paused session is still worth showing', (tester) async {
    // Time on the clock and nothing running is exactly the state Jess is in
    // while she reads the dog's notes — the bar is how she gets back.
    final timer = await pumpBar(tester);
    timer.openFor(dogId: 1, dogName: 'Teddy');
    timer.setMinutes('PREP', 12);
    await tester.pump();

    expect(find.textContaining('Teddy'), findsOneWidget);
    expect(find.text('12:00'), findsOneWidget);
  });
}
