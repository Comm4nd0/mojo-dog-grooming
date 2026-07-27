import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'booking_form_screen.dart';
import 'dog_profile_screen.dart';

/// The diary. Month and day views over the same data, with the to-do list
/// docked at the bottom as a collapsible sheet.
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
  List<TodoItem> _todos = const [];
  bool _loading = true;
  Object? _error;
  bool _todosExpanded = false;

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
      final todos = await _data.getTodos();
      if (!mounted) return;

      final grouped = <DateTime, List<Appointment>>{};
      for (final appointment in appointments) {
        final key = _dayKey(appointment.startAt);
        grouped.putIfAbsent(key, () => []).add(appointment);
      }
      setState(() {
        _byDay = grouped;
        _todos = todos;
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
        onPressed: () => _openBooking(),
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
                      border: Border.all(color: AppColors.primary),
                    ),
                    formatButtonTextStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary,
                    ),
                  ),
                  calendarStyle: const CalendarStyle(
                    todayDecoration: BoxDecoration(
                      color: AppColors.surfaceTint,
                      shape: BoxShape.rectangle,
                    ),
                    todayTextStyle: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700),
                    selectedDecoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.rectangle,
                    ),
                    markerDecoration: BoxDecoration(
                      color: AppColors.primaryBright,
                      shape: BoxShape.rectangle,
                    ),
                    markersMaxCount: 4,
                    outsideDaysVisible: false,
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _dayList()),
                _todoSheet(),
              ],
            ),
    );
  }

  Widget _dayList() {
    if (_loading && _byDay.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final appointments = _eventsFor(_selectedDay)..sort((a, b) => a.startAt.compareTo(b.startAt));
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
                style: const TextStyle(fontSize: 11, color: AppColors.inkSecondary),
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
              TemperamentChip(temperament: appointment.dogTemperament, compact: true),
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

  Widget _todoSheet() {
    final outstanding = _todos.where((todo) => !todo.isDone).length;
    return Material(
      elevation: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _todosExpanded = !_todosExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.checklist, size: 20, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Text('To-do', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  if (outstanding > 0)
                    InfoTag(label: '$outstanding outstanding'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    onPressed: _addTodo,
                  ),
                  Icon(_todosExpanded ? Icons.expand_more : Icons.expand_less),
                ],
              ),
            ),
          ),
          if (_todosExpanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: _todos.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'Nothing on the list.',
                        style: TextStyle(color: AppColors.inkSecondary, fontSize: 13),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final todo in _todos)
                          Dismissible(
                            key: ValueKey(todo.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: AppColors.error,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: const Icon(Icons.delete, color: Colors.white),
                            ),
                            onDismissed: (_) async {
                              await _data.deleteTodo(todo.id);
                              _load();
                            },
                            child: CheckboxListTile(
                              dense: true,
                              value: todo.isDone,
                              onChanged: (value) async {
                                await _data.updateTodo(todo.id, {'is_done': value});
                                _load();
                              },
                              title: Text(
                                todo.text,
                                style: TextStyle(
                                  decoration: todo.isDone ? TextDecoration.lineThrough : null,
                                  color: todo.isDone ? AppColors.inkSecondary : null,
                                ),
                              ),
                              subtitle: todo.dueDate == null
                                  ? null
                                  : Text('Due ${formatDate(todo.dueDate!)}'),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                          ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  Future<void> _addTodo() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to the list'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'e.g. Order more shampoo'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('ADD'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    await _data.createTodo(text.trim());
    setState(() => _todosExpanded = true);
    _load();
  }
}
