import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'booking_form_screen.dart';
import 'dog_profile_screen.dart';

/// The diary. Month and day views over the same data.
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

  CalendarFormat _format = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();

  Map<DateTime, List<Appointment>> _byDay = {};
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
      final from = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
      final to = DateTime(_focusedDay.year, _focusedDay.month + 2, 0);
      final appointments = await _data.getAppointments(from: from, to: to);
      if (!mounted) return;

      final grouped = <DateTime, List<Appointment>>{};
      for (final appointment in appointments) {
        final key = _dayKey(appointment.startAt);
        grouped.putIfAbsent(key, () => []).add(appointment);
      }
      setState(() {
        _byDay = grouped;
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
        title: const Text('Calendar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.today_outlined),
            tooltip: 'Today',
            onPressed: () => setState(() {
              _focusedDay = DateTime.now();
              _selectedDay = DateTime.now();
            }),
          ),
        ],
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
          : Column(
              children: [
                TableCalendar<Appointment>(
                  firstDay: DateTime.utc(2020),
                  lastDay: DateTime.utc(2035),
                  focusedDay: _focusedDay,
                  calendarFormat: _format,
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  eventLoader: _eventsFor,
                  availableCalendarFormats: const {
                    CalendarFormat.month: 'Month',
                    CalendarFormat.week: 'Day',
                  },
                  onFormatChanged: (format) => setState(() => _format = format),
                  onDaySelected: (selected, focused) => setState(() {
                    _selectedDay = selected;
                    _focusedDay = focused;
                  }),
                  onPageChanged: (focused) {
                    _focusedDay = focused;
                    _load();
                  },
                  headerStyle: HeaderStyle(
                    formatButtonShowsNext: false,
                    titleTextStyle: AppColors.display(20),
                    formatButtonDecoration: BoxDecoration(
                      border: Border.all(color: context.mojo.accent),
                    ),
                    formatButtonTextStyle: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: context.mojo.accent,
                    ),
                  ),
                  calendarStyle: CalendarStyle(
                    todayDecoration: BoxDecoration(
                      color: context.mojo.tint,
                      shape: BoxShape.rectangle,
                    ),
                    todayTextStyle: TextStyle(
                      color: context.mojo.onTint, fontWeight: FontWeight.w700,
                    ),
                    // A filled block, so it takes the website's bright green
                    // — the deep green is for text and icons. Black label,
                    // never white: white on this green fails contrast badly.
                    selectedDecoration: const BoxDecoration(
                      color: AppColors.primaryBright,
                      shape: BoxShape.rectangle,
                    ),
                    selectedTextStyle: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                    markerDecoration: BoxDecoration(
                      color: AppColors.primaryBright,
                      shape: BoxShape.rectangle,
                    ),
                    markersMaxCount: 4,
                    // Show the tail of last month and the head of next, so a
                    // month that doesn't begin on a Monday still shows the
                    // 30th and 31st in the row above the 1st. They stay
                    // tappable — onDaySelected gets the real date.
                    outsideDaysVisible: true,
                    outsideTextStyle: TextStyle(color: context.mojo.muted),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _dayList()),
              ],
            ),
    );
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
