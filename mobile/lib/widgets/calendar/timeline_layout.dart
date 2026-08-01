/// Working out where each booking sits on the day.
///
/// Pure: no widgets, no BuildContext, no clock. Everything here is arithmetic
/// on times and rectangles, which is exactly the part worth testing directly —
/// a golden of the rendered diary would fail at midnight and assert less.
library;

import '../../models/models.dart';
import 'timeline_metrics.dart';

/// One booking, with the rectangle it occupies worked out.
class PlacedAppointment {
  const PlacedAppointment({
    required this.appointment,
    required this.column,
    required this.columnCount,
    required this.startMinutes,
    required this.durationMinutes,
  });

  final Appointment appointment;

  /// Which lane within its overlapping cluster, from 0.
  final int column;

  /// How many lanes that cluster needed.
  final int columnCount;

  /// Minutes from the top of the visible day.
  final int startMinutes;
  final int durationMinutes;

  double top(TimelineMetrics metrics) => metrics.yForMinutes(startMinutes);
  double height(TimelineMetrics metrics) => metrics.heightForDuration(durationMinutes);

  /// Whether the cluster is drawn as an offset cascade rather than split.
  ///
  /// Up to three deep, blocks are inset from the left and stacked so the
  /// earlier one's leading edge — which carries its time and the dog's name —
  /// stays visible. That is Jess's "still able to overlap a bit". Beyond
  /// three the offsets would run off the screen, so they split evenly.
  bool get cascades => columnCount <= 3;

  double left(double laneWidth) =>
      cascades ? column * TimelineMetrics.overlapInset : column * (laneWidth / columnCount);

  double width(double laneWidth) =>
      cascades ? laneWidth - column * TimelineMetrics.overlapInset : laneWidth / columnCount;
}

/// The visible window of a day, in minutes past midnight.
class DayWindow {
  const DayWindow({required this.startMinutes, required this.endMinutes});

  final int startMinutes;
  final int endMinutes;

  int get totalMinutes => endMinutes - startMinutes;

  double height(TimelineMetrics metrics) => metrics.yForMinutes(totalMinutes);
}

/// Earliest and latest the diary will show without being asked.
const int _defaultOpenMinutes = 7 * 60;
const int _defaultCloseMinutes = 19 * 60;

/// Works out how much of the day to draw.
///
/// Widened to cover anything actually booked, because Jess works outside her
/// opening hours often enough that `opening_hours_warning` only warns — a
/// window fixed to her hours would clip real bookings off the top or bottom
/// where nobody would see them.
DayWindow dayWindowFor(
  List<Appointment> appointments, {
  int? openMinutes,
  int? closeMinutes,
}) {
  var start = openMinutes ?? _defaultOpenMinutes;
  var end = closeMinutes ?? _defaultCloseMinutes;

  for (final appointment in appointments) {
    final from = _minutesOfDay(appointment.startAt);
    final to = from + appointment.durationMinutes;
    if (from < start) start = from;
    if (to > end) end = to;
  }

  // Whole hours, and never narrower than the default window — an empty day
  // should not collapse to a one-hour strip.
  start = (start ~/ 60) * 60;
  end = ((end + 59) ~/ 60) * 60;
  if (start > _defaultOpenMinutes) start = _defaultOpenMinutes;
  if (end < _defaultCloseMinutes) end = _defaultCloseMinutes;

  return DayWindow(
    startMinutes: start.clamp(0, 24 * 60),
    endMinutes: end.clamp(60, 24 * 60),
  );
}

int _minutesOfDay(DateTime value) => value.hour * 60 + value.minute;

/// Places a day's bookings into lanes.
///
/// Bookings that overlap transitively form a cluster, and every block in a
/// cluster gets the same lane count so they line up. Within a cluster, lanes
/// are assigned greedy first-fit: each booking takes the **lowest-numbered**
/// lane that is free by the time it starts.
///
/// That "lowest-numbered" is the whole trick, and getting it wrong is the
/// classic bug in a hand-rolled diary. Given 09:00–10:00, 09:30–10:30 and
/// 10:15–11:00, the third does not overlap the first, so it belongs back in
/// lane 0 — a naive implementation puts it in lane 2 and makes the day look
/// three-deep when it is only ever two.
List<PlacedAppointment> layoutDay(
  List<Appointment> appointments,
  DayWindow window,
) {
  if (appointments.isEmpty) return const [];

  final sorted = [...appointments]..sort((a, b) => a.startAt.compareTo(b.startAt));

  final placed = <PlacedAppointment>[];
  var cluster = <Appointment>[];
  var clusterEnd = 0;

  void flush() {
    if (cluster.isEmpty) return;
    placed.addAll(_placeCluster(cluster, window));
    cluster = [];
  }

  for (final appointment in sorted) {
    final start = _minutesOfDay(appointment.startAt);
    final end = start + _safeDuration(appointment);
    if (cluster.isNotEmpty && start >= clusterEnd) {
      flush();
      clusterEnd = 0;
    }
    cluster.add(appointment);
    if (end > clusterEnd) clusterEnd = end;
  }
  flush();

  return placed;
}

/// Duration, guarded.
///
/// A booking whose end is at or before its start would otherwise produce a
/// negative height and throw during paint. Treated as a moment rather than
/// dropped, so a broken row is visible and fixable instead of silently absent.
int _safeDuration(Appointment appointment) {
  final minutes = appointment.durationMinutes;
  return minutes > 0 ? minutes : 1;
}

List<PlacedAppointment> _placeCluster(List<Appointment> cluster, DayWindow window) {
  // laneEnds[i] is when lane i next becomes free, in minutes past midnight.
  final laneEnds = <int>[];
  final lanes = <int>[];

  for (final appointment in cluster) {
    final start = _minutesOfDay(appointment.startAt);
    final end = start + _safeDuration(appointment);

    var lane = laneEnds.indexWhere((freeAt) => freeAt <= start);
    if (lane == -1) {
      lane = laneEnds.length;
      laneEnds.add(end);
    } else {
      laneEnds[lane] = end;
    }
    lanes.add(lane);
  }

  final columnCount = laneEnds.length;
  return [
    for (var i = 0; i < cluster.length; i++)
      PlacedAppointment(
        appointment: cluster[i],
        column: lanes[i],
        columnCount: columnCount,
        startMinutes: _minutesOfDay(cluster[i].startAt) - window.startMinutes,
        durationMinutes: _safeDuration(cluster[i]),
      ),
  ];
}
