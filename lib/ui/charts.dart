import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// "3:42 PM" today, "yesterday 3:42 PM", else "Oct 22, 3:42 PM".
String whenText(BuildContext context, DateTime d) {
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(d).format(context);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return time;
  if (day == today.subtract(const Duration(days: 1))) return 'yesterday $time';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, $time';
}

String agoText(DateTime d) {
  final s = DateTime.now().difference(d).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

/// Stress, HRV and heart rate over the 24 hours up to the last reading — the chart stays put
/// with no new data, showing the last report and its date until a newer one replaces it.
class HealthCharts extends StatelessWidget {
  const HealthCharts({
    super.key,
    required this.series,
    required this.heartRate,
    this.emptyText = 'No Health readings yet.',
  });
  final List<({DateTime at, double hrv, double stress})> series;
  final List<({DateTime at, double bpm})> heartRate;
  final String emptyText;

  static Color stressColor(double s) => s < 35
      ? AppTheme.lime
      : s < 65
      ? AppTheme.amber
      : AppTheme.danger;

  @override
  Widget build(BuildContext context) {
    final latest = [
      if (series.isNotEmpty) series.last.at,
      if (heartRate.isNotEmpty) heartRate.last.at,
    ].fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final end = (latest ?? DateTime.now()).add(const Duration(minutes: 5));
    final start = end.subtract(const Duration(hours: 24));
    double x(DateTime t) => t.difference(start).inMinutes / 60;
    final titles = FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: const AxisTitles(
        sideTitles: SideTitles(showTitles: true, reservedSize: 32),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          interval: 6,
          reservedSize: 22,
          getTitlesWidget: (v, _) {
            final t = start.add(Duration(minutes: (v * 60).round()));
            return Text(
              '${t.hour}',
              style: const TextStyle(fontSize: 10, color: AppTheme.subtitle),
            );
          },
        ),
      ),
    );
    final grid = FlGridData(
      drawVerticalLine: false,
      getDrawingHorizontalLine: (_) =>
          const FlLine(color: Colors.white12, strokeWidth: 1),
    );
    Widget chart(
      List<FlSpot> spots,
      Color color, {
      double? minY,
      double? maxY,
      bool dots = true,
      List<Color>? dotColors,
    }) => SizedBox(
      height: 130,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: 24,
          minY: minY,
          maxY: maxY,
          gridData: grid,
          titlesData: titles,
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              preventCurveOverShooting:
                  true, // smooth, but never past the readings
              color: color,
              barWidth: 1.8,
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.12),
              ),
              dotData: FlDotData(
                show: dots,
                getDotPainter: (s, _, _, i) => FlDotCirclePainter(
                  radius: 2.6,
                  color: dotColors != null && i < dotColors.length
                      ? dotColors[i]
                      : color,
                  strokeWidth: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final shownSeries = series.where((s) => s.at.isAfter(start)).toList();
    final shownHR = heartRate.where((h) => h.at.isAfter(start)).toList();
    final label = const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppTheme.subtitle,
    );
    return Glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            latest == null
                ? 'Last 24 hours'
                : '24 hours to ${whenText(context, latest)}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          if (latest == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Text(emptyText, style: label)),
            )
          else ...[
            Text(
              'Last reading ${whenText(context, latest)} · ${agoText(latest)}',
              style: TextStyle(
                fontSize: 11,
                color:
                    DateTime.now().difference(latest) > const Duration(hours: 6)
                    ? AppTheme.amber
                    : AppTheme.subtitle,
              ),
            ),
            if (shownSeries.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Stress — every reading', style: label),
              chart(
                [for (final s in shownSeries) FlSpot(x(s.at), s.stress)],
                Colors.white54,
                minY: 0,
                maxY: 100,
                dotColors: [for (final s in shownSeries) stressColor(s.stress)],
              ),
              Text('HRV (ms) — higher is more rested', style: label),
              chart(
                [for (final s in shownSeries) FlSpot(x(s.at), s.hrv)],
                AppTheme.accent,
                minY: 0,
              ),
            ],
            if (shownHR.isNotEmpty) ...[
              Text('Heart rate (bpm)', style: label),
              chart(
                [for (final h in shownHR) FlSpot(x(h.at), h.bpm)],
                AppTheme.danger,
                dots: false,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
