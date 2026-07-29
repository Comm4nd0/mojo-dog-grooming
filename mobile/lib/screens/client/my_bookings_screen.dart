import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// A client's own bookings — read-only, plus the ability to request one.
///
/// Requests land as REQUESTED for Jess to confirm; only she can actually book,
/// move or cancel.
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  final _data = getIt<DataService>();

  List<Appointment> _appointments = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final appointments = await _data.getAppointments(
        from: DateTime.now().subtract(const Duration(days: 180)),
        to: DateTime.now().add(const Duration(days: 365)),
      );
      if (!mounted) return;
      setState(() {
        _appointments = appointments;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<Appointment> get _upcoming {
    final now = DateTime.now();
    return _appointments.where((a) => a.startAt.isAfter(now) && !a.isCancelled).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
  }

  List<Appointment> get _past {
    final now = DateTime.now();
    return _appointments.where((a) => !a.startAt.isAfter(now) || a.isCancelled).toList()
      ..sort((a, b) => b.startAt.compareTo(a.startAt));
  }

  Future<void> _request() async {
    final dogs = await _data.getDogs();
    if (!mounted) return;
    if (dogs.isEmpty) {
      showSnack(context, 'No dogs on your account yet.', isError: true);
      return;
    }

    int dogId = dogs.first.id;
    DateTime date = DateTime.now().add(const Duration(days: 7));
    TimeOfDay time = const TimeOfDay(hour: 10, minute: 0);
    final notes = TextEditingController();

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Request an appointment',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                'Mojo and Co will confirm a time with you.',
                style: TextStyle(fontSize: 12.5, color: context.mojo.muted),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: dogId,
                decoration: const InputDecoration(labelText: 'Dog'),
                items: [
                  for (final dog in dogs)
                    DropdownMenuItem(value: dog.id, child: Text(dog.name)),
                ],
                onChanged: (value) => setSheetState(() => dogId = value ?? dogId),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) setSheetState(() => date = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Preferred date'),
                        child: Text(formatDate(date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked =
                            await showTimePicker(context: context, initialTime: time);
                        if (picked != null) setSheetState(() => time = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Preferred time'),
                        child: Text(time.format(context)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Anything to mention?'),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('SEND REQUEST'),
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await _data.createAppointment(
          dogId: dogId,
          startAt: DateTime(date.year, date.month, date.day, time.hour, time.minute),
          notes: notes.text.trim(),
        );
        if (!mounted) return;
        showSnack(context, 'Request sent. Mojo and Co will be in touch.');
        _load();
      } catch (error) {
        if (mounted) showSnack(context, error.toString(), isError: true);
      }
    }
    notes.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My bookings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _request,
        icon: const Icon(Icons.add),
        label: const Text('REQUEST'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      const SectionHeader(title: 'Upcoming'),
                      if (_upcoming.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text(
                            'Nothing booked in.',
                            style: TextStyle(color: context.mojo.muted, fontSize: 13),
                          ),
                        )
                      else
                        for (final appointment in _upcoming) _row(appointment),
                      if (_past.isNotEmpty) ...[
                        const SectionHeader(title: 'Past'),
                        for (final appointment in _past.take(20)) _row(appointment, past: true),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _row(Appointment appointment, {bool past = false}) {
    return ListTile(
      leading: Icon(
        appointment.status == 'REQUESTED' ? Icons.hourglass_empty : Icons.event,
        color: past ? context.mojo.muted : context.mojo.accent,
      ),
      title: Text(
        appointment.dogName,
        style: TextStyle(
          decoration: appointment.isCancelled ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        '${formatDate(appointment.startAt)} · ${appointment.timeRange}',
      ),
      trailing: appointment.status == 'BOOKED'
          ? null
          : InfoTag(
              label: appointment.statusLabel,
              color: switch (appointment.status) {
                'REQUESTED' => AppColors.warning,
                'CONFIRMED' => AppColors.success,
                'CANCELLED' || 'NO_SHOW' => AppColors.error,
                _ => context.mojo.muted,
              },
            ),
    );
  }
}
