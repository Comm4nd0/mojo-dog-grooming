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
    this.companions = const [],
  });

  final Appointment appointment;

  /// The other dogs of the same visit drawn **inside this block** rather
  /// than as blocks of their own — only those with exactly this start and
  /// end. A companion Jess has made a different length is honest about it
  /// and gets its own block.
  final List<Appointment> companions;

  /// Every dog on the block, this one first.
  List<Appointment> get all => [appointment, ...companions];

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

/// A blocked-out span, with the rectangle it occupies worked out.
///
/// Blocks do not take lanes. They sit full-width **under** the bookings,
/// because the case that matters is Jess deliberately booking over her own
/// block — a warning, never a refusal — and the booking has to stay
/// readable on top of it.
class PlacedBlock {
  const PlacedBlock({
    required this.block,
    required this.startMinutes,
    required this.durationMinutes,
  });

  final BlockedTime block;

  /// Minutes from the top of the visible day.
  final int startMinutes;
  final int durationMinutes;

  double top(TimelineMetrics metrics) => metrics.yForMinutes(startMinutes);
  double height(TimelineMetrics metrics) => metrics.heightForDuration(durationMinutes);
}

/// Places the blocks that touch [day] on the window.
///
/// A block that runs past midnight either side is clipped to the day, so a
/// long weekend off paints Saturday top to bottom rather than not at all.
List<PlacedBlock> layoutBlocks(
  List<BlockedTime> blocks,
  DateTime day,
  DayWindow window,
) {
  final placed = <PlacedBlock>[];
  for (final block in blocks) {
    final span = block.minutesOn(day);
    if (span == null) continue;
    final (from, to) = span;
    // Clip to the drawn window as well: the window is widened to cover
    // blocks, but never below 00:00 or past 24:00, and nothing else here
    // ever hands a negative top to `Positioned`.
    final start = from < window.startMinutes ? window.startMinutes : from;
    final end = to > window.endMinutes ? window.endMinutes : to;
    if (end <= start) continue;
    placed.add(PlacedBlock(
      block: block,
      startMinutes: start - window.startMinutes,
      durationMinutes: end - start,
    ));
  }
  return placed;
}

/// Statuses a booking can be in and still be linked into a visit.
///
/// Not a request (nothing is booked yet) and not a finished one (the visit
/// is over, and re-shaping it would rewrite history).
const Set<String> kLinkableStatuses = {'BOOKED', 'CONFIRMED', 'IN_PROGRESS'};

/// Households with two or more dogs booked **separately** on one day.
///
/// The case visits exist for, found in the diary as it stands: every
/// booking made one dog at a time before visits existed looks like this.
/// Each entry is that owner's loose bookings, earliest first, so the caller
/// can offer to link them and open the leading one.
List<List<Appointment>> householdsBookedSeparately(List<Appointment> appointments) {
  final byClient = <int, List<Appointment>>{};
  for (final appointment in appointments) {
    if (appointment.groupId != null) continue;
    if (!kLinkableStatuses.contains(appointment.status)) continue;
    byClient.putIfAbsent(appointment.clientId, () => []).add(appointment);
  }
  return [
    for (final members in byClient.values)
      if (members.length >= 2) (members..sort(_byStartThenId)),
  ];
}

int _byStartThenId(Appointment a, Appointment b) {
  final byStart = a.startAt.compareTo(b.startAt);
  return byStart != 0 ? byStart : a.id.compareTo(b.id);
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
///
/// [spans] are extra `(from, to)` minute ranges the window must also cover —
/// blocked-out time, already clipped to the day by [BlockedTime.minutesOn].
/// A block from 06:00 that the window did not stretch to would be invisible,
/// and an invisible block is one Jess books over by accident.
DayWindow dayWindowFor(
  List<Appointment> appointments, {
  List<(int, int)> spans = const [],
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
  for (final (from, to) in spans) {
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

  final sorted = _mergeVisits(appointments)
    ..sort((a, b) => a.appointment.startAt.compareTo(b.appointment.startAt));

  final placed = <PlacedAppointment>[];
  var cluster = <_Item>[];
  var clusterEnd = 0;

  void flush() {
    if (cluster.isEmpty) return;
    placed.addAll(_placeCluster(cluster, window));
    cluster = [];
  }

  for (final item in sorted) {
    final start = _minutesOfDay(item.appointment.startAt);
    final end = start + _safeDuration(item.appointment);
    if (cluster.isNotEmpty && start >= clusterEnd) {
      flush();
      clusterEnd = 0;
    }
    cluster.add(item);
    if (end > clusterEnd) clusterEnd = end;
  }
  flush();

  return placed;
}

/// One block on the axis: a booking, plus the visit-mates it stands for.
class _Item {
  _Item(this.appointment, this.companions);

  final Appointment appointment;
  final List<Appointment> companions;
}

/// Folds a household visit into one block.
///
/// Dogs in the same visit with the **same start and end** become one item,
/// led by the lowest id so the choice is stable across reloads. Any member
/// with a different shape stays its own block: five dogs from 10:00 to
/// 14:00 are one band with five names, and the one whose nail trim Jess
/// shortened to twenty minutes is drawn as twenty minutes, because the
/// alternative is a diary that says otherwise.
List<_Item> _mergeVisits(List<Appointment> appointments) {
  final byShape = <(int, DateTime, DateTime), List<Appointment>>{};
  final loose = <Appointment>[];
  for (final appointment in appointments) {
    final group = appointment.groupId;
    if (group == null) {
      loose.add(appointment);
      continue;
    }
    byShape
        .putIfAbsent((group, appointment.startAt, appointment.endAt), () => [])
        .add(appointment);
  }
  final items = [for (final a in loose) _Item(a, const [])];
  for (final members in byShape.values) {
    members.sort((a, b) => a.id.compareTo(b.id));
    items.add(_Item(members.first, members.sublist(1)));
  }
  return items;
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

List<PlacedAppointment> _placeCluster(List<_Item> cluster, DayWindow window) {
  // laneEnds[i] is when lane i next becomes free, in minutes past midnight.
  final laneEnds = <int>[];
  final lanes = <int>[];

  for (final item in cluster) {
    final appointment = item.appointment;
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
        appointment: cluster[i].appointment,
        companions: cluster[i].companions,
        column: lanes[i],
        columnCount: columnCount,
        startMinutes: _minutesOfDay(cluster[i].appointment.startAt) - window.startMinutes,
        durationMinutes: _safeDuration(cluster[i].appointment),
      ),
  ];
}
