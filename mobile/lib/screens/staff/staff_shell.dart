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

/// The width at which the shells swap bottom tabs for a side rail.
///
/// Material's "expanded" breakpoint. Below it (every phone in portrait) the
/// layout is untouched; at or above it — an iPad, or a big phone on its side —
/// a bottom bar spends the scarcest dimension on navigation, so the tabs move
/// to a [NavigationRail] on the left instead.
const double kRailBreakpoint = 840;

/// Jess's app. Three destinations: her dog list, her diary, and everything else.
class StaffShell extends StatefulWidget {
  const StaffShell({super.key});

  @override
  State<StaffShell> createState() => _StaffShellState();
}

class _StaffShellState extends State<StaffShell> {
  int _index = 0;

  static const _screens = [
    DogumentsScreen(),
    CalendarScreen(),
    MoreScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kRailBreakpoint;

    if (wide) {
      // The timer strips stay pinned to the bottom of the content area — the
      // rail replaces the tabs, not the "a running clock is always visible"
      // rule.
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.pets_outlined),
                  selectedIcon: Icon(Icons.pets),
                  label: Text('Doguments'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  selectedIcon: Icon(Icons.calendar_month),
                  label: Text('Calendar'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.more_horiz_outlined),
                  selectedIcon: Icon(Icons.more_horiz),
                  label: Text('More'),
                ),
              ],
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: IndexedStack(index: _index, children: _screens)),
                  const GroomTimerBar(),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
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

/// The running groom timers, shown on every staff screen while any runs.
///
/// Nothing at all when there is no session, so it costs no room the rest of
/// the time. **One strip per dog**, because the service holds a session per
/// dog now — Bunny drying in the crate while Teddy is in the bath is two
/// clocks, and hiding one is how it gets left on. Tapping a strip goes back
/// to that dog's timer.
class GroomTimerBar extends StatelessWidget {
  const GroomTimerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final timer = getIt<GroomTimerService>();
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final sessions = timer.liveSessions;
        if (sessions.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final session in sessions) _row(context, session),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, GroomTimerSession session) {
    final phase = session.runningPhase;
    return Material(
      color: session.isRunning ? AppColors.primaryBright : context.mojo.tint,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GroomTimerScreen(
              dogId: session.dogId,
              dogName: session.dogName,
              usualMinutes: session.usualMinutes,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                session.isRunning ? Icons.timer : Icons.pause_circle_outline,
                size: 20,
                color: session.isRunning ? Colors.black : context.mojo.onTint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  phase == null
                      ? '${session.dogName} — paused'
                      : '${session.dogName} — ${PhaseTiming.labelFor(phase)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: session.isRunning ? Colors.black : context.mojo.onTint,
                  ),
                ),
              ),
              Text(
                formatClock(session.totalSeconds),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: session.isRunning ? Colors.black : context.mojo.onTint,
                ),
              ),
            ],
          ),
        ),
      ),
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
