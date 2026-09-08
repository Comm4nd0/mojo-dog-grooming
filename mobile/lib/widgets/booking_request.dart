import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/models.dart';
import '../services/data_service.dart';
import 'common.dart';

/// What Jess can do with a booking a client has asked for.
///
/// Shared by the diary (tapping a REQUESTED block) and the Waiting for you
/// queue (tapping the row), so the two places she meets a request offer the
/// same answers. They used to hold two copies of the same book-in code, and
/// neither could change the time: "at the time they asked for" was the only
/// way in, and the only way to a different one was the edit form, where the
/// status dropdown still had to be moved by hand or the request stayed a
/// request with a new time on it.
enum RequestDecision {
  /// Put it in the diary at the time the client asked for.
  accept,

  /// Put it in the diary somewhere else — Jess picks the date and time.
  acceptElsewhen,

  /// Cancel it.
  decline,

  /// Open the booking form to change more than the time.
  open,

  /// Ring the client.
  ring,
}

/// The decision sheet for a client's booking request.
Future<RequestDecision?> showRequestDecisionSheet(
  BuildContext context,
  Appointment request,
) {
  return showModalBottomSheet<RequestDecision>(
    context: context,
    // Six rows plus a header is taller than a modal sheet gets on a short
    // phone (9/16 of the screen), so it scrolls rather than clipping the
    // ring row off the bottom.
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                '${request.dogName} — requested by ${request.clientName}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '${formatDate(request.startAt)} · ${request.timeRange}'
                '${request.notes.isEmpty ? '' : '\n“${request.notes}”'}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: sheetContext.mojo.muted,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.check, color: sheetContext.mojo.accent),
              title: const Text('Book it in'),
              subtitle: const Text('At the time they asked for'),
              onTap: () => Navigator.pop(sheetContext, RequestDecision.accept),
            ),
            ListTile(
              leading: Icon(Icons.schedule, color: sheetContext.mojo.accent),
              title: const Text('Book it in at a different time'),
              subtitle: Text(
                'Pick the date and time — it stays ${formatDuration(request.length.inMinutes)}',
              ),
              onTap: () =>
                  Navigator.pop(sheetContext, RequestDecision.acceptElsewhen),
            ),
            ListTile(
              leading: const Icon(Icons.close, color: AppColors.error),
              title: const Text('Turn it down'),
              onTap: () => Navigator.pop(sheetContext, RequestDecision.decline),
            ),
            ListTile(
              leading: Icon(
                Icons.edit_calendar_outlined,
                color: sheetContext.mojo.accent,
              ),
              title: const Text('Open the booking'),
              subtitle: const Text('Change the dog, services or length first'),
              onTap: () => Navigator.pop(sheetContext, RequestDecision.open),
            ),
            if (request.clientPhone.isNotEmpty)
              ListTile(
                leading: Icon(
                  Icons.phone_outlined,
                  color: sheetContext.mojo.accent,
                ),
                title: Text('Ring ${request.clientName}'),
                onTap: () => Navigator.pop(sheetContext, RequestDecision.ring),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// A date, then a time, starting from [initial]. Null if either is cancelled.
///
/// The same two pickers the booking form uses, in the same order and with
/// the keypad first — `input`, not `inputOnly`, because Jess asked to keep
/// the clock face. Used wherever a request is being put in the diary at a
/// time other than the one asked for, so it is one picker to learn.
Future<DateTime?> pickDateAndTime(
  BuildContext context, {
  required DateTime initial,
}) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: now.subtract(const Duration(days: 365)),
    lastDate: now.add(const Duration(days: 730)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
    initialEntryMode: TimePickerEntryMode.input,
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Put a client's request in the diary, at the time asked or at [at].
///
/// Checks first — not to refuse, the diary never refuses, but because a
/// request arrives without anyone having looked at the day, so this is the
/// first moment a clash or an out-of-hours slot is visible. The slot keeps
/// its length when it moves: see [Appointment.length].
///
/// Returns true once the booking is made. False means Jess went back, or it
/// failed and she has been told.
Future<bool> bookRequestIn(
  BuildContext context,
  DataService data,
  Appointment request, {
  DateTime? at,
}) async {
  final startAt = at ?? request.startAt;
  final endAt = at == null ? request.endAt : request.endIfStartedAt(at);
  try {
    final check = await data.checkBooking(
      dogId: request.dogId,
      startAt: startAt,
      endAt: endAt,
      excludeAppointmentId: request.id,
      serviceType: request.serviceType,
      serviceIds: request.serviceIds,
    );
    if (!context.mounted) return false;
    final go = await showWarningsDialog(
      context,
      check,
      title: 'Before you book them in',
      confirmLabel: 'BOOK ANYWAY',
    );
    if (!go || !context.mounted) return false;
    await data.updateAppointment(request.id, {
      'status': 'BOOKED',
      if (at != null) 'start_at': startAt.toUtc().toIso8601String(),
      if (at != null) 'end_at': endAt.toUtc().toIso8601String(),
    });
  } catch (error) {
    if (context.mounted) showSnack(context, error.toString(), isError: true);
    return false;
  }
  if (!context.mounted) return true;
  // Say where it landed when it moved. There are no notifications, so this
  // snack is the only thing that tells Jess the client is expecting the time
  // they asked for and not this one — the prompt to ring them.
  showSnack(
    context,
    at == null
        ? 'Booked in.'
        : 'Booked in for ${formatDate(at)} · ${formatTime(at)}. They asked for '
              '${formatDate(request.startAt)} · ${formatTime(request.startAt)}, '
              'so let them know.',
  );
  return true;
}
