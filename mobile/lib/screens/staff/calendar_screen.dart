import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/calendar/day_timeline.dart';
import '../../widgets/calendar/timeline_metrics.dart';
import '../../widgets/calendar/week_timeline.dart';
import '../../widgets/common.dart';
import 'booking_form_screen.dart';
import 'dog_profile_screen.dart';

/// How much of the diary is on screen at once.
enum CalendarView { day, week, month }

/// The diary.
///
/// Three views over the same data. **Day is the default**: it is the one Jess
/// works from, and it is the one she asked to have blocked out on a time axis
/// so a clash is visible while she is still booking.
///
/// The month grid is still `table_calendar` — it handles the six-week layout
/// and the leading and trailing days of adjacent months correctly, and
/// rewriting that buys nothing. The day and week views are built here, because
/// no package could express "show the server's warnings and move it anyway".
///
/// The to-do list used to be docked at the bottom of this screen; it lives
/// under More now — see [TodosScreen] for why.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _data = getIt<DataService>();

  CalendarView _view = CalendarView.day;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  Map<DateTime, List<Appointment>> _byDay = {};
  Map<int, (int, int)> _hoursByWeekday = const {};
  Set<DateTime> _closures = const {};
  TimelineMetrics _metrics = const TimelineMetrics();
  DateTime _loadedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  int? _movingId;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Load a wide window around the focused month so scrolling between months
  /// doesn't trigger a fetch every swipe.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final from = DateTime(_loadedMonth.year, _loadedMonth.month - 1, 1);
      final to = DateTime(_loadedMonth.year, _loadedMonth.month + 2, 0);
      final appointments = await _data.getAppointments(from: from, to: to);
      // Opening hours shade the closed parts of the day, and closures wash
      // the whole thing. Both are advisory — a booking on a closed day still
      // renders, because the rule warns and never blocks.
      var hours = _hoursByWeekday;
      var closures = _closures;
      try {
        hours = await _data.getOpeningHoursByWeekday();
        closures = await _data.getClosureDates();
      } catch (_) {
        // The grid is still readable without the shading.
      }
      if (!mounted) return;

      final grouped = <DateTime, List<Appointment>>{};
      for (final appointment in appointments) {
        final key = _dayKey(appointment.startAt);
        grouped.putIfAbsent(key, () => []).add(appointment);
      }
      setState(() {
        _byDay = grouped;
        _hoursByWeekday = hours;
        _closures = closures;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  static DateTime _dayKey(DateTime value) => DateTime.utc(value.year, value.month, value.day);

  List<Appointment> _eventsFor(DateTime day) => _byDay[_dayKey(day)] ?? const [];

  Future<void> _openBooking({Appointment? existing, DateTime? at}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookingFormScreen(appointment: existing, initialDate: at ?? _selectedDay),
      ),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          // A button rather than pull-to-refresh, deliberately. The day view's
          // blocks are dragged vertically to move a booking, and a
          // RefreshIndicator over the same surface would race that gesture —
          // a slow downward drag near the top would sometimes reload the
          // screen instead of sliding the groom, which is the one interaction
          // Jess asked for by name.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.today_outlined),
            tooltip: 'Today',
            onPressed: () => setState(() {
              _focusedDay = DateTime.now();
              _selectedDay = DateTime.now();
            }),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<CalendarView>(
              segments: const [
                ButtonSegment(value: CalendarView.day, label: Text('Day')),
                ButtonSegment(value: CalendarView.week, label: Text('Week')),
                ButtonSegment(value: CalendarView.month, label: Text('Month')),
              ],
              selected: {_view},
              showSelectedIcon: false,
              onSelectionChanged: (value) => setState(() => _view = value.first),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        // Straight to a new booking. It used to open a sheet offering
        // "booking" or "to-do", because the FAB sat on top of the to-do
        // dock's own add button — with the to-dos gone the + means one thing
        // again.
        onPressed: () => _openBooking(at: _selectedDay),
        tooltip: 'New booking',
        child: const Icon(Icons.add),
      ),
      body: _error != null && _byDay.isEmpty
          ? ErrorRetry(error: _error!, onRetry: _load)
          : switch (_view) {
              CalendarView.day => _dayView(),
              CalendarView.week => _weekView(),
              CalendarView.month => _monthView(),
            },
    );
  }

  String get _title => switch (_view) {
        CalendarView.day => formatDate(_selectedDay),
        CalendarView.week => '${formatDate(_mondayOf(_selectedDay))} – '
            '${formatDate(_mondayOf(_selectedDay).add(const Duration(days: 6)))}',
        CalendarView.month => 'Calendar',
      };

  static DateTime _mondayOf(DateTime day) =>
      DateTime(day.year, day.month, day.day)
          .subtract(Duration(days: day.weekday - 1));

  // ── Day ────────────────────────────────────────────────────────────

  Widget _dayView() {
    final closed = _closures.contains(_dayKey(_selectedDay));
    final hours = _hoursByWeekday[_selectedDay.weekday];

    return Column(
      children: [
        _dayStrip(),
        const Divider(height: 1),
        if (closed)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.warning.withValues(alpha: 0.12),
            child: const Text(
              'Marked closed. Anything already booked still shows.',
              style: TextStyle(fontSize: 12.5, color: AppColors.warning),
            ),
          ),
        Expanded(
          child: GestureDetector(
            // Pinch changes the layout, not a pixel zoom, so a nail trim can
            // be made thumb-sized without the text blurring. One finger is
            // left alone so the timeline still scrolls.
            onScaleUpdate: (details) {
              if (details.pointerCount < 2) return;
              setState(
                () => _metrics = _metrics.withScale(_metrics.scale * details.scale),
              );
            },
            child: DayTimeline(
              key: ValueKey(_dayKey(_selectedDay)),
              day: _selectedDay,
              appointments: _eventsFor(_selectedDay),
              metrics: _metrics,
              openMinutes: hours?.$1,
              closeMinutes: hours?.$2,
              isClosedDay: closed,
              movingId: _movingId,
              onOpen: (appointment) => _openBooking(existing: appointment),
              onCreateAt: (at) => _openBooking(at: at),
              onMove: _move,
            ),
          ),
        ),
      ],
    );
  }

  /// A week of dates across the top, so changing day is one tap.
  Widget _dayStrip() {
    final monday = _mondayOf(_selectedDay);
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous week',
            onPressed: () =>
                _selectDay(_selectedDay.subtract(const Duration(days: 7))),
          ),
          for (var i = 0; i < 7; i++)
            Expanded(child: _dayChip(monday.add(Duration(days: i)))),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next week',
            onPressed: () => _selectDay(_selectedDay.add(const Duration(days: 7))),
          ),
        ],
      ),
    );
  }

  Widget _dayChip(DateTime day) {
    final selected = _dayKey(day) == _dayKey(_selectedDay);
    final isToday = _dayKey(day) == _dayKey(DateTime.now());
    final count = _eventsFor(day).length;
    return InkWell(
      onTap: () => _selectDay(day),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? context.mojo.tint : null,
          // Jess's request: something on the date strip that says which one is
          // today. It has to be a *border* rather than a fill, because the
          // fill already means "the day you are looking at" — and the two are
          // different questions. Red for the same reason the now-line is red:
          // one colour for "this is now", used nowhere else on this screen.
          //
          // Drawn on today whether or not it is selected, so tapping ahead a
          // few days never leaves the strip with no anchor on it.
          border: isToday ? Border.all(color: AppColors.error, width: 1.5) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              weekdayInitial(day.weekday),
              style: TextStyle(
                fontSize: 10,
                color: selected ? context.mojo.onTint : context.mojo.muted,
              ),
            ),
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? context.mojo.onTint : null,
              ),
            ),
            SizedBox(
              height: 6,
              child: count == 0
                  ? null
                  : Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      color: selected ? context.mojo.onTint : context.mojo.accent,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _selectDay(DateTime day) {
    setState(() {
      _selectedDay = day;
      _focusedDay = day;
    });
    _loadIfOutsideWindow(day);
  }

  // ── Week ───────────────────────────────────────────────────────────

  Widget _weekView() {
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous week',
              onPressed: () =>
                  _selectDay(_selectedDay.subtract(const Duration(days: 7))),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next week',
              onPressed: () => _selectDay(_selectedDay.add(const Duration(days: 7))),
            ),
          ],
        ),
        Expanded(
          child: WeekTimeline(
            weekStart: _mondayOf(_selectedDay),
            appointmentsByDay: _byDay,
            // Zoomed out by default so the whole week fits without scrolling
            // — scanning is the point of this view.
            metrics: const TimelineMetrics(scale: 0.55),
            onOpen: (appointment) => _openBooking(existing: appointment),
            onOpenDay: (day) => setState(() {
              _selectedDay = day;
              _view = CalendarView.day;
            }),
          ),
        ),
      ],
    );
  }

  // ── Month ──────────────────────────────────────────────────────────

  Widget _monthView() {
    return Column(
      children: [
        TableCalendar<Appointment>(
          firstDay: DateTime.utc(2020),
          lastDay: DateTime.utc(2035),
          focusedDay: _focusedDay,
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.monday,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          eventLoader: _eventsFor,
          availableCalendarFormats: const {CalendarFormat.month: 'Month'},
          onDaySelected: (selected, focused) {
            // Tapping the day you are already on drops into it — one extra
            // tap, no extra chrome.
            if (_dayKey(selected) == _dayKey(_selectedDay)) {
              setState(() => _view = CalendarView.day);
              return;
            }
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
          },
          onPageChanged: (focused) {
            _focusedDay = focused;
            _loadIfOutsideWindow(focused);
          },
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: AppColors.display(20),
          ),
          // "Now" at month scale is a day, not a time — there is no hour to
          // put a line at. This is the same red rule the day and week views
          // draw, moved to the top edge of today's cell.
          //
          // `prioritizedBuilder` rather than `todayBuilder` because the
          // builders are tried in order and `selectedBuilder` wins first: with
          // todayBuilder, selecting today made it stop looking like today,
          // which is exactly when you are most likely to be looking at it.
          // Returning null for every other day falls through to the normal
          // styling, and markers still draw on top either way.
          calendarBuilders: CalendarBuilders(
            prioritizedBuilder: (context, day, focusedDay) {
              if (!isSameDay(day, DateTime.now())) return null;
              final selected = isSameDay(_selectedDay, day);
              return Container(
                margin: const EdgeInsets.all(6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppColors.primaryBright : context.mojo.tint,
                  border: const Border(
                    top: BorderSide(color: AppColors.error, width: 2.5),
                  ),
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    // Black on the bright green, never white — it fails
                    // contrast badly. Same rule as selectedTextStyle below.
                    color: selected ? Colors.black : context.mojo.onTint,
                  ),
                ),
              );
            },
          ),
          calendarStyle: CalendarStyle(
            todayDecoration: BoxDecoration(
              color: context.mojo.tint,
              shape: BoxShape.rectangle,
            ),
            todayTextStyle: TextStyle(
              color: context.mojo.onTint,
              fontWeight: FontWeight.w700,
            ),
            // A filled block, so it takes the website's bright green — the
            // deep green is for text and icons. Black label, never white:
            // white on this green fails contrast badly.
            selectedDecoration: const BoxDecoration(
              color: AppColors.primaryBright,
              shape: BoxShape.rectangle,
            ),
            selectedTextStyle: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
            markerDecoration: const BoxDecoration(
              color: AppColors.primaryBright,
              shape: BoxShape.rectangle,
            ),
            markersMaxCount: 4,
            // Show the tail of last month and the head of next, so a month
            // that doesn't begin on a Monday still shows the 30th and 31st in
            // the row above the 1st. They stay tappable — onDaySelected gets
            // the real date.
            outsideDaysVisible: true,
            outsideTextStyle: TextStyle(color: context.mojo.muted),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _dayList()),
      ],
    );
  }

  // ── Moving a booking ───────────────────────────────────────────────

  /// Commits a drag: check, confirm, PATCH, offer an undo.
  ///
  /// The warnings are advisory here exactly as they are when booking — "MOVE
  /// ANYWAY" is always available. `excludeAppointmentId` is not optional:
  /// without it every move overlaps itself and warns about the very booking
  /// being dragged.
  Future<void> _move(Appointment appointment, DateTime newStart) async {
    final original = appointment.startAt;
    final newEnd = newStart.add(Duration(minutes: appointment.durationMinutes));
    setState(() => _movingId = appointment.id);

    try {
      final check = await _data.checkBooking(
        dogId: appointment.dogId,
        startAt: newStart,
        endAt: newEnd,
        excludeAppointmentId: appointment.id,
        serviceType: appointment.serviceType,
        serviceIds: appointment.serviceIds,
      );
      if (!mounted) return;

      final proceed = await showWarningsDialog(
        context,
        check,
        title: 'Before you move it',
        confirmLabel: 'MOVE ANYWAY',
        cancelLabel: 'PUT IT BACK',
      );
      if (!proceed) {
        setState(() => _movingId = null);
        return;
      }

      await _data.updateAppointment(appointment.id, {
        'start_at': newStart.toUtc().toIso8601String(),
        'end_at': newEnd.toUtc().toIso8601String(),
      });
      if (!mounted) return;
      showSnackWithUndo(
        context,
        '${appointment.dogName} moved to ${formatTime(newStart)}.',
        onUndo: () => _undoMove(appointment, original),
      );
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _movingId = null);
      _load();
    }
  }

  Future<void> _undoMove(Appointment appointment, DateTime original) async {
    try {
      await _data.updateAppointment(appointment.id, {
        'start_at': original.toUtc().toIso8601String(),
        'end_at': original
            .add(Duration(minutes: appointment.durationMinutes))
            .toUtc()
            .toIso8601String(),
      });
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
    _load();
  }

  /// Refetch only when the date is near the edge of what is already loaded.
  ///
  /// `_load` used to run on every page change, so every swipe cost a round
  /// trip. The window is a month either side, so day and week movement inside
  /// it is free.
  void _loadIfOutsideWindow(DateTime day) {
    final from = DateTime(_loadedMonth.year, _loadedMonth.month - 1, 1);
    final to = DateTime(_loadedMonth.year, _loadedMonth.month + 2, 0);
    if (day.isBefore(from.add(const Duration(days: 7))) ||
        day.isAfter(to.subtract(const Duration(days: 7)))) {
      _loadedMonth = DateTime(day.year, day.month);
      _load();
    }
  }

  Widget _dayList() {
    if (_loading && _byDay.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // Copy before sorting: an empty day yields the shared `const []`, which
    // throws on sort, and sorting in place would mutate _byDay during build.
    final appointments = [..._eventsFor(_selectedDay)]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    if (appointments.isEmpty) {
      return EmptyState(
        icon: Icons.event_available_outlined,
        title: 'Nothing booked',
        message: formatDate(_selectedDay),
        action: ElevatedButton(
          onPressed: () => _openBooking(at: _selectedDay),
          child: const Text('ADD A BOOKING'),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: appointments.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final appointment = appointments[index];
        return ListTile(
          onTap: () => _openBooking(existing: appointment),
          leading: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                formatTime(appointment.startAt),
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              Text(
                formatDuration(appointment.durationMinutes),
                style: TextStyle(fontSize: 11, color: context.mojo.muted),
              ),
            ],
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  appointment.dogName,
                  style: TextStyle(
                    decoration: appointment.isCancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TemperamentChip(
                temperament: appointment.dogTemperament,
                label: appointment.dogTemperamentDisplay,
                compact: true,
              ),
            ],
          ),
          subtitle: Text(
            '${appointment.clientName} · ${appointment.bookingTypeLabel}'
            '${appointment.status == 'BOOKED' ? '' : ' · ${appointment.statusLabel}'}',
          ),
          trailing: IconButton(
            icon: const Icon(Icons.pets_outlined),
            tooltip: 'Dog profile',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DogProfileScreen(dogId: appointment.dogId)),
            ),
          ),
        );
      },
    );
  }

}
