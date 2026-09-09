import 'dart:async';

import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/booking_request.dart';
import '../../widgets/calendar/day_timeline.dart';
import '../../widgets/calendar/timeline_layout.dart';
import '../../widgets/calendar/timeline_metrics.dart';
import '../../widgets/calendar/week_timeline.dart';
import '../../widgets/common.dart';
import '../../widgets/contact_actions.dart';
import 'blocked_time_form_screen.dart';
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
  const CalendarScreen({super.key, this.initialDate});

  /// Opens the diary on this day rather than today. Set when the screen is
  /// *pushed* — "see it in the diary" from the Waiting for you queue — rather
  /// than sitting in the shell as a tab.
  final DateTime? initialDate;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _data = getIt<DataService>();

  CalendarView _view = CalendarView.day;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  Map<DateTime, List<Appointment>> _byDay = {};

  /// Blocked-out time, under every day it touches. A block that runs across
  /// a weekend is in Saturday's list as well as Friday's.
  Map<DateTime, List<BlockedTime>> _blocksByDay = {};
  Map<int, (int, int)> _hoursByWeekday = const {};
  Set<DateTime> _closures = const {};
  TimelineMetrics _metrics = const TimelineMetrics();
  DateTime _loadedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  int? _movingId;
  bool _loading = true;
  Object? _error;

  /// The day view is a pager, one page per calendar day, so a swipe carries
  /// the diary to the next day the way a paper one turns. It is created
  /// when the day view is shown and thrown away when it is left: a
  /// `PageController` that is re-attached goes back to its `initialPage`
  /// rather than where it was, so the honest thing is a fresh one that
  /// starts on the day actually selected.
  PageController? _pager;

  /// Fingers on the day view right now. Two of them are a pinch, which
  /// changes the axis scale — and must not also be read as a swipe.
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDate;
    if (initial != null) {
      _focusedDay = initial;
      _selectedDay = initial;
      _loadedMonth = DateTime(initial.year, initial.month);
    }
    _load();
  }

  @override
  void dispose() {
    _pager?.dispose();
    super.dispose();
  }

  // ── Pages are days ─────────────────────────────────────────────────
  //
  // Page 0 is the first day the month grid can reach; every later day is
  // its distance from there. Nothing is ever "loaded" into the pager — it
  // is arithmetic, and `_eventsFor` answers for any date, empty or not.

  // Counted in UTC, deliberately. A local-time difference from January to
  // August is a whole number of days *minus an hour* for the clocks going
  // forward, and `inDays` truncates — every page in summer came out one day
  // early. A calendar day has no length to get wrong in UTC.
  static final DateTime _firstPage = DateTime.utc(2020, 1, 1);

  static int _pageOf(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day).difference(_firstPage).inDays;

  static DateTime _dayOfPage(int page) {
    final utc = DateTime.utc(2020, 1, 1 + page);
    return DateTime(utc.year, utc.month, utc.day);
  }

  void _setView(CalendarView view) {
    if (view != CalendarView.day) {
      _pager?.dispose();
      _pager = null;
    }
    setState(() => _view = view);
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
      // Blocked time is fetched separately and a failure leaves the last
      // answer standing rather than blanking the diary: bookings are the
      // thing Jess cannot work without, the bands are the thing she set up.
      var blocks = _blocksByDay;
      try {
        blocks = _groupBlocks(await _data.getBlockedTimes(from: from, to: to), from, to);
      } catch (_) {
        // Shown without them.
      }
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
        _blocksByDay = blocks;
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

  /// One entry per day a block touches, within the loaded window.
  static Map<DateTime, List<BlockedTime>> _groupBlocks(
    List<BlockedTime> blocks,
    DateTime from,
    DateTime to,
  ) {
    final grouped = <DateTime, List<BlockedTime>>{};
    for (final block in blocks) {
      var day = DateTime(block.startAt.year, block.startAt.month, block.startAt.day);
      if (day.isBefore(from)) day = DateTime(from.year, from.month, from.day);
      while (!day.isAfter(to) && block.coversDay(day)) {
        grouped.putIfAbsent(_dayKey(day), () => []).add(block);
        day = DateTime(day.year, day.month, day.day + 1);
      }
    }
    return grouped;
  }

  List<Appointment> _eventsFor(DateTime day) => _byDay[_dayKey(day)] ?? const [];

  List<BlockedTime> _blocksFor(DateTime day) => _blocksByDay[_dayKey(day)] ?? const [];

  /// Block time out, or open a block already there.
  Future<void> _openBlock({BlockedTime? existing, DateTime? at}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BlockedTimeFormScreen(
          block: existing,
          initialStart: at ?? _selectedDay,
        ),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _openBooking({Appointment? existing, DateTime? at}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookingFormScreen(appointment: existing, initialDate: at ?? _selectedDay),
      ),
    );
    if (saved == true) _load();
  }

  /// What tapping a block does.
  ///
  /// A client's request opens a decision sheet rather than the edit form —
  /// Jess: *"within the 'Waiting for you' requests can there be an option to
  /// view the item in the diary, then have the ability to approve/deny it
  /// from there?"*. The diary is where the clash is visible, so the diary is
  /// where the answer should be one tap away. Everything else opens the form
  /// as before.
  Future<void> _openAppointment(Appointment appointment) async {
    if (appointment.status != 'REQUESTED') {
      await _openBooking(existing: appointment);
      return;
    }

    final choice = await showRequestDecisionSheet(context, appointment);
    if (!mounted || choice == null) return;

    switch (choice) {
      case RequestDecision.accept:
        await _acceptRequest(appointment);
      case RequestDecision.acceptElsewhen:
        await _acceptRequestElsewhen(appointment);
      case RequestDecision.decline:
        await _declineRequest(appointment);
      case RequestDecision.open:
        await _openBooking(existing: appointment);
      case RequestDecision.ring:
        await callNumber(context, appointment.clientPhone);
    }
  }

  /// A band with several dogs on it: ask which one.
  ///
  /// The visit is a link between bookings and nothing more — each dog keeps
  /// its own notes, services, price, status and timer — so opening "the
  /// visit" has to mean opening one dog's booking, and the diary should not
  /// guess which.
  Future<void> _chooseFromVisit(List<Appointment> dogs) async {
    final chosen = await showModalBottomSheet<Appointment>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.group_outlined, size: 18, color: sheetContext.mojo.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${dogs.first.clientName} · ${dogs.first.timeRange}',
                      style: Theme.of(sheetContext).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'One visit, ${dogs.length} bookings. Which dog?',
                  style: TextStyle(fontSize: 12.5, color: sheetContext.mojo.muted),
                ),
              ),
            ),
            for (final dog in dogs)
              ListTile(
                leading: const Icon(Icons.pets_outlined),
                title: Text(dog.dogName),
                subtitle: dog.status == 'BOOKED'
                    ? null
                    : Text(dog.statusLabel),
                onTap: () => Navigator.pop(sheetContext, dog),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) await _openAppointment(chosen);
  }

  /// Book it at the time asked. The check-then-confirm shape lives in
  /// [bookRequestIn], shared with the Waiting for you queue.
  Future<void> _acceptRequest(Appointment request) async {
    if (!await bookRequestIn(context, _data, request)) return;
    if (!mounted) return;
    _load();
    unawaited(_data.getPending());
  }

  /// Book it at a time Jess picks instead — the request is what the client
  /// would like, and what she has free is a different question. The slot
  /// keeps its length; only the start moves.
  Future<void> _acceptRequestElsewhen(Appointment request) async {
    final at = await pickDateAndTime(context, initial: request.startAt);
    if (at == null || !mounted) return;
    if (!await bookRequestIn(context, _data, request, at: at)) return;
    if (!mounted) return;
    _selectDay(at);
    _load();
    unawaited(_data.getPending());
  }

  Future<void> _declineRequest(Appointment request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Turn down ${request.dogName}?'),
        content: const Text(
          'The booking is cancelled. Ring them if you want to offer another '
          'time — there are no notifications, so nothing tells them by itself.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('KEEP IT'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('TURN IT DOWN', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _data.updateAppointment(request.id, {'status': 'CANCELLED'});
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    showSnack(context, 'Turned down.');
    _load();
    unawaited(_data.getPending());
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
          // Its own button rather than a second thing behind the +. The FAB
          // has just gone back to meaning one thing, and blocking time out
          // is rarer than booking a dog.
          IconButton(
            icon: const Icon(Icons.event_busy_outlined),
            tooltip: 'Block out time',
            onPressed: () => _openBlock(at: _selectedDay),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.today_outlined),
            tooltip: 'Today',
            onPressed: () => _selectDay(DateTime.now()),
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
              onSelectionChanged: (value) => _setView(value.first),
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
    final pager = _pager ??= PageController(initialPage: _pageOf(_selectedDay));
    return Column(
      children: [
        _dayStrip(),
        const Divider(height: 1),
        Expanded(
          // Jess: can swiping left and right go through the days? One page
          // per day; the strip above follows, and a tap on the strip or a
          // date on the month grid slides the pager to match.
          child: Listener(
            onPointerDown: (_) => setState(() => _pointers++),
            onPointerUp: (_) => setState(() => _pointers = (_pointers - 1).clamp(0, 99)),
            onPointerCancel: (_) => setState(() => _pointers = (_pointers - 1).clamp(0, 99)),
            child: PageView.builder(
              key: const ValueKey('day-pager'),
              controller: pager,
              // A pinch is a scale, never a swipe. With two fingers down the
              // pager stands still and the scale detector inside gets both.
              physics: _pointers >= 2
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: (page) => _selectDay(_dayOfPage(page), fromPager: true),
              itemBuilder: (context, page) => _dayPage(_dayOfPage(page)),
            ),
          ),
        ),
      ],
    );
  }

  /// One day of the diary: its banners and its timeline.
  Widget _dayPage(DateTime day) {
    final closed = _closures.contains(_dayKey(day));
    final hours = _hoursByWeekday[day.weekday];

    return Column(
      children: [
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
        // A household booked one dog at a time — every booking made before
        // visits existed looks like this. Offered, never done unasked.
        for (final household in householdsBookedSeparately(_eventsFor(day)))
          _linkBanner(household),
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
              key: ValueKey(_dayKey(day)),
              day: day,
              appointments: _eventsFor(day),
              blocks: _blocksFor(day),
              onOpenBlock: (block) => _openBlock(existing: block),
              metrics: _metrics,
              openMinutes: hours?.$1,
              closeMinutes: hours?.$2,
              isClosedDay: closed,
              movingId: _movingId,
              onOpen: _openAppointment,
              onOpenVisit: _chooseFromVisit,
              onCreateAt: (at) => _openBooking(at: at),
              onMove: _move,
            ),
          ),
        ),
      ],
    );
  }

  /// "Rolo, Tank and Pip are booked separately — link as one visit?"
  Widget _linkBanner(List<Appointment> household) {
    final names = _joinNames([for (final a in household) a.dogName]);
    return Material(
      color: context.mojo.tintWash,
      child: InkWell(
        onTap: () => _linkVisit(household),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.group_outlined, size: 18, color: context.mojo.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$names are booked separately.',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: () => _linkVisit(household),
                child: const Text('LINK AS ONE VISIT'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _joinNames(List<String> names) {
    if (names.length <= 1) return names.join();
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  /// Link the household's bookings into one visit, then open it.
  ///
  /// Linking moves nothing. The bookings keep the shapes they had, which
  /// is exactly what made the diary wrong — so the leading booking's form
  /// opens straight after with the "also change the others" switch on, and
  /// the visit's length is one edit away rather than five.
  Future<void> _linkVisit(List<Appointment> household) async {
    List<Appointment> members;
    try {
      members = await _data.groupAppointments([for (final a in household) a.id]);
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    final names = _joinNames([for (final a in household) a.dogName]);
    showSnack(context, 'Linked $names as one visit. Set how long they are in.');
    members.sort((a, b) {
      final byStart = a.startAt.compareTo(b.startAt);
      return byStart != 0 ? byStart : a.id.compareTo(b.id);
    });
    await _openBooking(existing: members.first);
    if (mounted) _load();
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
    final marks = dayMarks(_eventsFor(day), _blocksFor(day));
    // The strip has room for a yes/no, not a count: one green mark if
    // anything is booked, one red mark if anything is blocked out. The
    // month grid below is where the marks are counted.
    final booked = marks.contains(DayMark.visit);
    final blocked = marks.contains(DayMark.blocked);
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (booked)
                    _mark(selected ? context.mojo.onTint : context.mojo.accent),
                  if (booked && blocked) const SizedBox(width: 2),
                  if (blocked) _mark(AppColors.error),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A 4dp square — square, like everything else on this brand. Red is the
  /// one colour on the diary that never means a dog: the now-line, today's
  /// border, and a blocked-out day all share it.
  static Widget _mark(Color colour) => Container(
        width: 4,
        height: 4,
        margin: const EdgeInsets.only(top: 2),
        color: colour,
      );

  /// Lands on a day. From anywhere but the pager itself — the strip, the
  /// chevrons, Today, the month grid — the pager slides to match; from the
  /// pager it is already there, and animating it again would fight the
  /// finger that just put it there.
  void _selectDay(DateTime day, {bool fromPager = false}) {
    setState(() {
      _selectedDay = day;
      _focusedDay = day;
    });
    _loadIfOutsideWindow(day);
    final pager = _pager;
    if (fromPager || pager == null || !pager.hasClients) return;
    final target = _pageOf(day);
    if ((pager.page ?? pager.initialPage).round() == target) return;
    // A week away in one hop rather than a seven-day flick-book.
    final far = ((pager.page ?? target) - target).abs() > 3;
    if (far) {
      pager.jumpToPage(target);
    } else {
      pager.animateToPage(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
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
            blocksByDay: _blocksByDay,
            onOpenBlock: (block) => _openBlock(existing: block),
            // Zoomed out by default so the whole week fits without scrolling
            // — scanning is the point of this view.
            metrics: const TimelineMetrics(scale: 0.55),
            onOpen: _openAppointment,
            onOpenVisit: _chooseFromVisit,
            onOpenDay: (day) {
              _selectDay(day);
              _setView(CalendarView.day);
            },
          ),
        ),
      ],
    );
  }

  // ── Month ──────────────────────────────────────────────────────────

  Widget _monthView() {
    return Column(
      children: [
        TableCalendar<DayMark>(
          firstDay: DateTime.utc(2020),
          lastDay: DateTime.utc(2035),
          focusedDay: _focusedDay,
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.monday,
          selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
          // Marks, not bookings: a household booked as one visit is one
          // mark however many dogs are in it, and a blocked-out day gets a
          // red one. `dayMarks` is the rule; `markerBuilder` below draws it.
          eventLoader: (day) => dayMarks(_eventsFor(day), _blocksFor(day)),
          availableCalendarFormats: const {CalendarFormat.month: 'Month'},
          onDaySelected: (selected, focused) {
            // Tapping the day you are already on drops into it — one extra
            // tap, no extra chrome.
            if (_dayKey(selected) == _dayKey(_selectedDay)) {
              _setView(CalendarView.day);
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
            markerBuilder: (context, day, marks) {
              if (marks.isEmpty) return null;
              // At most four green marks, the way the package capped it,
              // but the red one is never the one that gets dropped: a day
              // with five visits and a block must still say it is blocked.
              final visits = marks.where((m) => m == DayMark.visit).length;
              final blocked = marks.contains(DayMark.blocked);
              return Positioned(
                bottom: 5,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < visits.clamp(0, 4); i++)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 0.6),
                        color: AppColors.primaryBright,
                      ),
                    if (blocked)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 0.6),
                        color: AppColors.error,
                      ),
                  ],
                ),
              );
            },
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
            // The markers themselves are drawn by `markerBuilder` above —
            // these two only apply when it returns null, which it does for
            // a day with nothing on it.
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
      // A dog booked in with the rest of its household: ask whether the
      // visit moves or just the one dog, before anything is checked. Asked,
      // not assumed — the whole point of a visit is that a change to it is
      // deliberate.
      var wholeVisit = false;
      if (appointment.isSharedVisit) {
        final choice = await _askWholeVisit(appointment);
        if (choice == null) {
          setState(() => _movingId = null);
          return;
        }
        wholeVisit = choice;
      }

      final check = await _data.checkBooking(
        dogId: appointment.dogId,
        startAt: newStart,
        endAt: newEnd,
        excludeAppointmentId: appointment.id,
        excludeGroupId: wholeVisit ? appointment.groupId : null,
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

      if (wholeVisit) {
        await _data.updateBookingGroup(appointment.groupId!, startAt: newStart);
        if (!mounted) return;
        final names = [appointment.dogName, ...appointment.companionNames].join(', ');
        showSnackWithUndo(
          context,
          '$names moved to ${formatTime(newStart)}.',
          onUndo: () => _undoMove(appointment, original, wholeVisit: true),
        );
      } else {
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
      }
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _movingId = null);
      _load();
    }
  }

  /// Whole visit (true), just this dog (false), or put it back (null).
  Future<bool?> _askWholeVisit(Appointment appointment) {
    final names = appointment.companionNames.join(', ');
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Move the whole visit?'),
        content: Text(
          '${appointment.dogName} is booked in with $names. Move them all, '
          'or just ${appointment.dogName}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('PUT IT BACK'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('JUST ${appointment.dogName.toUpperCase()}'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('MOVE ALL'),
          ),
        ],
      ),
    );
  }

  Future<void> _undoMove(
    Appointment appointment,
    DateTime original, {
    bool wholeVisit = false,
  }) async {
    try {
      if (wholeVisit) {
        await _data.updateBookingGroup(appointment.groupId!, startAt: original);
      } else {
        await _data.updateAppointment(appointment.id, {
          'start_at': original.toUtc().toIso8601String(),
          'end_at': original
              .add(Duration(minutes: appointment.durationMinutes))
              .toUtc()
              .toIso8601String(),
        });
      }
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
    final blocks = [..._blocksFor(_selectedDay)]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    if (appointments.isEmpty && blocks.isEmpty) {
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
      itemCount: blocks.length + appointments.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index < blocks.length) return _blockRow(blocks[index]);
        final appointment = appointments[index - blocks.length];
        return ListTile(
          onTap: () => _openAppointment(appointment),
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

  /// A blocked span in the month view's list, ahead of the bookings.
  Widget _blockRow(BlockedTime block) {
    final span = block.minutesOn(_selectedDay);
    final (from, to) = span ?? (0, 24 * 60);
    String clock(int minutes) => minutes >= 24 * 60
        ? '24:00'
        : '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
    final headline = block.headline;
    return ListTile(
      onTap: () => _openBlock(existing: block),
      leading: Icon(Icons.event_busy_outlined, color: context.mojo.muted),
      title: Text('Blocked out · ${clock(from)} – ${clock(to)}'),
      subtitle: headline.isEmpty ? null : Text(headline),
    );
  }
}
