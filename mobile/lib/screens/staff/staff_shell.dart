import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/groom_timer_service.dart';
import '../../services/service_locator.dart';
import 'calendar_screen.dart';
import 'doguments_screen.dart';
import 'groom_timer_screen.dart';
import 'more_screen.dart';

/// Jess's app. Three destinations: her dog list, her diary, and everything else.
class StaffShell extends StatefulWidget {
  const StaffShell({super.key});

  @override
  State<StaffShell> createState() => _StaffShellState();
}

class _StaffShellState extends State<StaffShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          DogumentsScreen(),
          CalendarScreen(),
          MoreScreen(),
        ],
      ),
      // A timer that survives leaving its screen has to be visible from
      // wherever you went, or it is just a timer that gets left on. Sits above
      // the tabs so it is on every staff screen without each one knowing.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GroomTimerBar(),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.pets_outlined),
                selectedIcon: Icon(Icons.pets),
                label: 'Doguments',
              ),
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month),
                label: 'Calendar',
              ),
              NavigationDestination(
                icon: Icon(Icons.more_horiz_outlined),
                selectedIcon: Icon(Icons.more_horiz),
                label: 'More',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The running groom timer, shown on every staff screen while it runs.
///
/// Nothing at all when there is no session, so it costs no room the rest of
/// the time. Tapping it goes back to the timer.
class GroomTimerBar extends StatelessWidget {
  const GroomTimerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final timer = getIt<GroomTimerService>();
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        if (!timer.hasSession) return const SizedBox.shrink();
        final phase = timer.runningPhase;
        return Material(
          color: timer.isRunning ? AppColors.primaryBright : context.mojo.tint,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => GroomTimerScreen(
                  dogId: timer.dogId!,
                  dogName: timer.dogName,
                  usualMinutes: timer.usualMinutes,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    timer.isRunning ? Icons.timer : Icons.pause_circle_outline,
                    size: 20,
                    color: timer.isRunning ? Colors.black : context.mojo.onTint,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      phase == null
                          ? '${timer.dogName} — paused'
                          : '${timer.dogName} — ${PhaseTiming.labelFor(phase)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: timer.isRunning ? Colors.black : context.mojo.onTint,
                      ),
                    ),
                  ),
                  Text(
                    formatClock(timer.totalSeconds),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: timer.isRunning ? Colors.black : context.mojo.onTint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Sign-out action shared by the staff and client shells.
Future<void> confirmSignOut(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You will need your username and password to sign back in.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('SIGN OUT')),
      ],
    ),
  );
  if (confirmed == true) await getIt<AuthService>().signOut();
}
