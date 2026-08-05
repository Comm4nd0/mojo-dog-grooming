import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/contact_actions.dart';
import 'booking_form_screen.dart';
import 'dog_profile_screen.dart';

/// Who needs booking in.
///
/// The dog profile has always been able to say when *one* dog is next due, but
/// only if Jess already thought to look — which means a client who quietly
/// stops coming is never noticed. This does the same sum across the whole book
/// and puts a phone number next to it.
///
/// Dogs already in the diary are left out by the server. That is deliberate and
/// it is the whole point: a list that included them would be a report, and the
/// handful worth ringing would be buried in it.
class DueScreen extends StatefulWidget {
  const DueScreen({super.key});

  @override
  State<DueScreen> createState() => _DueScreenState();
}

class _DueScreenState extends State<DueScreen> {
  final _data = getIt<DataService>();

  List<DueDog> _rows = const [];
  bool _loading = true;
  Object? _error;
  int _withinDays = 14;

  static const _windows = <int, String>{
    0: 'Overdue',
    14: 'A fortnight',
    30: 'A month',
    90: 'Three months',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Only blank the screen when there is nothing to keep. A refresh that
    // replaces a usable list with a spinner is worse than a stale list.
    if (_rows.isEmpty) setState(() => _loading = true);
    try {
      final rows = await _data.getDogsDue(withinDays: _withinDays);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
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

  Future<void> _setWindow(int days) async {
    setState(() => _withinDays = days);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final overdue = _rows.where((row) => row.isOverdue).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Due a groom'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final entry in _windows.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: _withinDays == entry.key,
                      onSelected: (_) => _setWindow(entry.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _buildBody(overdue),
    );
  }

  Widget _buildBody(int overdue) {
    if (_loading && _rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // Same rule as the refresh above: an error on reload must not throw away a
    // list Jess is working through.
    if (_error != null && _rows.isEmpty) {
      return ErrorRetry(error: _error!, onRetry: _load);
    }
    if (_rows.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Nobody is waiting',
        message: _withinDays == 0
            ? 'No dog is past its usual interval without a booking.'
            : 'Nothing falls due in the next $_withinDays days that is not already booked in.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _rows.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == 0) return _summary(overdue);
          return _row(_rows[index - 1]);
        },
      ),
    );
  }

  Widget _summary(int overdue) {
    final text = overdue == 0
        ? '${_rows.length} coming up'
        : '$overdue overdue of ${_rows.length}';
    return Container(
      width: double.infinity,
      color: context.mojo.tintWash,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              color: context.mojo.onTint,
            ),
          ),
          const SizedBox(height: 3),
          // Says what is *not* here as well as what is. A dog already in the
          // diary — including one seen earlier today — and any dog marked ad
          // hoc are deliberately absent. Without saying so, the list looks
          // like it has simply missed them, which is what sent Jess looking
          // for what she had done wrong.
          Text(
            'Dogs already in the diary and ad hoc dogs are left out.',
            style: TextStyle(fontSize: 11, color: context.mojo.muted),
          ),
        ],
      ),
    );
  }

  Widget _row(DueDog row) {
    // Never-groomed dogs are a different kind of unknown from an overdue one,
    // so they are not painted as urgent. See DueDog.dueDate.
    final Color colour = row.neverGroomed
        ? context.mojo.muted
        : row.isOverdue
            ? AppColors.error
            : context.mojo.accent;

    return ListTile(
      isThreeLine: true,
      title: Text(row.dogName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${row.breedLabel} · ${row.clientName}'),
          const SizedBox(height: 2),
          Text(
            row.whenLabel,
            style: TextStyle(color: colour, fontWeight: FontWeight.w600),
          ),
          Text(
            row.basis,
            style: TextStyle(fontSize: 11, color: context.mojo.muted),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (row.clientPhone.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.phone_outlined),
              color: context.mojo.accent,
              tooltip: 'Ring ${row.clientName}',
              onPressed: () => callNumber(context, row.clientPhone),
            ),
          IconButton(
            icon: const Icon(Icons.event_available_outlined),
            color: context.mojo.accent,
            tooltip: 'Book ${row.dogName} in',
            onPressed: () => _book(row),
          ),
        ],
      ),
      onTap: () => _openProfile(row),
    );
  }

  Future<void> _book(DueDog row) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookingFormScreen(
          // Today rather than the due date: a dog 40 days overdue would
          // otherwise open the form on a date already in the past.
          initialDate: DateTime.now(),
          initialDogId: row.dogId,
        ),
      ),
    );
    // Booking one is what takes it off this list, so reload rather than leave a
    // row that is now wrong.
    await _load();
  }

  Future<void> _openProfile(DueDog row) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DogProfileScreen(dogId: row.dogId)),
    );
    await _load();
  }
}
