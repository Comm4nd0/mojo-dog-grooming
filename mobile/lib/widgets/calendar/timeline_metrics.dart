/// Geometry for the time-axis diary.
///
/// One `scale` drives every dimension, borrowed from p4td's `_BoardSizing`.
/// Pinching changes the *layout*, not a pixel zoom, so text stays crisp and
/// stays legible rather than shrinking with everything else.
library;

class TimelineMetrics {
  const TimelineMetrics({this.scale = 1.0});

  /// 0.5 (a whole week at a glance) to 3.0 (a nail trim at thumb size).
  final double scale;

  static const double minScale = 0.5;
  static const double maxScale = 3.0;

  /// Height of one minute at scale 1.0.
  ///
  /// 1.2 gives **72dp an hour**, so a 07:00–20:00 window is 936dp — about 1.6
  /// phone screens. The whole working day is two thumb-flicks, which is the
  /// point; much tighter and a 20-minute nail trim is a sliver, much looser
  /// and Jess is scrolling all morning.
  static const double baseMinuteHeight = 1.2;

  /// Where a dragged block settles.
  ///
  /// Five, not fifteen. Jess genuinely books 09:10, and the paper cards are
  /// written to the minute. At scale 1.0 five minutes is 6dp — a detent you
  /// can feel without fighting.
  static const int snapMinutes = 5;

  /// A block never gets shorter than this, whatever its duration.
  ///
  /// A 20-minute nail visit is 24dp at scale 1.0; the clamp lifts it to 26.
  /// The two-dp lie is under two minutes of axis — the geometry stays honest
  /// while the block stays tappable.
  static const double minBlockHeight = 26;

  /// How far a cascaded block is pushed right of the one it overlaps.
  static const double overlapInset = 18;

  double get minuteHeight => baseMinuteHeight * scale;

  /// Width of the hour-label gutter.
  double get gutterWidth => 52;

  /// Font size for a block's label, on a gentler curve than the layout so
  /// names stay readable when zoomed out.
  double get blockFontSize => 12 * (0.65 + 0.35 * scale);

  double yForMinutes(int minutesFromStart) => minutesFromStart * minuteHeight;

  int minutesForY(double y) => (y / minuteHeight).round();

  double heightForDuration(int minutes) {
    final raw = minutes * minuteHeight;
    return raw < minBlockHeight ? minBlockHeight : raw;
  }

  /// Rounds to the nearest [snapMinutes].
  static int snap(int minutes) =>
      (minutes / snapMinutes).round() * snapMinutes;

  TimelineMetrics withScale(double value) => TimelineMetrics(
        scale: value.clamp(minScale, maxScale),
      );
}
