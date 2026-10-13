import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import 'booking_form_screen.dart';

/// All diary visits for one dog, reached from its next-booking row.
class DogBookingsScreen extends StatefulWidget {
  const DogBookingsScreen({
    super.key,
    required this.dogId,
    required this.dogName,
  });
  final int dogId;
  final String dogName;

  @override
  State<DogBookingsScreen> createState() => _DogBookingsScreenState();
}

class _DogBookingsScreenState extends State<DogBookingsScreen> {
  List<Appointment>? _bookings;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await getIt<DataService>().getAppointments(
        dogId: widget.dogId,
      );
      rows.sort((a, b) => a.startAt.compareTo(b.startAt));
      if (mounted) {
        setState(() {
          _bookings = rows;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final upcoming =
        _bookings
            ?.where((a) => !a.startAt.isBefore(today) && !a.isCancelled)
            .toList() ??
        [];
    final history =
        _bookings
            ?.where((a) => a.startAt.isBefore(today) || a.isCancelled)
            .toList()
            .reversed
            .toList() ??
        [];
    return Scaffold(
      appBar: AppBar(title: Text('${widget.dogName} — bookings')),
      body: PageBody(
        child: _error != null
            ? ErrorRetry(error: _error!, onRetry: _load)
            : _bookings == null
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  children: [
                    const SectionHeader(title: 'Upcoming visits'),
                    if (upcoming.isEmpty)
                      const ListTile(title: Text('Nothing booked')),
                    ...upcoming.map(_row),
                    if (history.isNotEmpty) ...[
                      const SectionHeader(title: 'Past and cancelled visits'),
                      ...history.map(_row),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _row(Appointment booking) => ListTile(
    title: Text('${formatDate(booking.startAt)} · ${booking.timeRange}'),
    subtitle: Text(booking.statusLabel),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BookingFormScreen(
            initialDate: booking.startAt,
            appointment: booking,
          ),
        ),
      );
      if (mounted) _load();
    },
  );
}
