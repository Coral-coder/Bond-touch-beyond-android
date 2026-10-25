import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../models/presence.dart';
import 'charts.dart';
import 'theme.dart';

/// Your personal battery and how you're feeling, from Health Connect and what you log, with
/// your charts and every partner's last reading.
class StressMoodPage extends StatelessWidget {
  const StressMoodPage({super.key, required this.model});
  final AppModel model;

  static const moods = [
    ('🥰', 'Loved', 'calm'),
    ('😌', 'Calm', 'calm'),
    ('🙂', 'Good', 'ok'),
    ('🤩', 'Excited', 'ok'),
    ('😴', 'Tired', 'low'),
    ('😕', 'Meh', 'low'),
    ('😢', 'Sad', 'low'),
    ('😟', 'Anxious', 'stressed'),
    ('😤', 'Frustrated', 'stressed'),
    ('😣', 'Stressed', 'stressed'),
    ('😵‍💫', 'Overwhelmed', 'overwhelmed'),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final h = model.health;
      final share = h.moodShare(logged: model.loggedMood);
      final battery = (share?['battery'] as num?)?.toInt();
      final face = battery == null ? null : MoodShare.face(100 - battery);
      return RefreshIndicator(
        onRefresh: () async {
          await h.refresh();
          await model.publishPresence(force: true);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Glass(
              child: Column(
                children: [
                  Text(
                    face?.emoji ?? '🫥',
                    style: const TextStyle(fontSize: 72),
                  ),
                  Text(
                    face?.label ?? '—',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (battery != null)
                    Text(
                      'Stress ${100 - battery} / 100 · energy $battery%',
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _stat(
                        'HRV',
                        h.hrv == null ? '—' : '${h.hrv!.round()} ms',
                        h.hrvBaseline == null
                            ? ''
                            : 'usual ${h.hrvBaseline!.round()}',
                      ),
                      _stat(
                        'Resting HR',
                        h.restingHR == null ? '—' : '${h.restingHR!.round()}',
                        'bpm',
                      ),
                      _stat(
                        'Sleep',
                        h.sleepHours == null
                            ? '—'
                            : '${h.sleepHours!.toStringAsFixed(1)} h',
                        'last night',
                      ),
                    ],
                  ),
                  if (h.readAt == null) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () async {
                        await h.requestAccess();
                        await h.refresh();
                        await model.publishPresence(force: true);
                      },
                      child: const Text('Allow Health Connect'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            HealthCharts(series: h.series, heartRate: h.heartRate),
            const SizedBox(height: 14),
            Glass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How are you feeling?',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in moods)
                        ChoiceChip(
                          label: Text('${m.$1} ${m.$2}'),
                          selected: model.loggedMood?.label == m.$2,
                          onSelected: (_) => model.logMood(
                            m.$1,
                            m.$2,
                            m.$3,
                            const {
                              'calm': 75,
                              'ok': 60,
                              'low': 35,
                              'stressed': 30,
                              'overwhelmed': 15,
                            }[m.$3]!,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Glass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your people',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  for (final p in model.partners) _partnerRow(context, p),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              value: model.shareMood,
              onChanged: model.setMoodSharing,
              title: const Text('Share with my partners'),
              subtitle: const Text(
                'Your battery, mood, HRV and heart rate. Notes stay on this phone.',
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _partnerRow(BuildContext context, Partner p) {
    final mood = p.presence?.mood;
    final lastHRV = mood?.series.lastOrNull;
    final lastHR = mood?.heartRate.lastOrNull;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Avatar(
        name: p.name,
        color: p.colorRGB,
        photo: p.photo,
        size: 40,
        online: p.online,
      ),
      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(
        mood == null
            ? 'No mood reported yet'
            : '${mood.emoji} ${mood.label} · ${whenText(context, mood.at)}'
                  '${lastHRV != null ? '\nHRV ${lastHRV.hrv.round()} ms · ${whenText(context, lastHRV.at)}' : ''}'
                  '${lastHR != null ? '\nHeart rate ${lastHR.bpm.round()} bpm · ${whenText(context, lastHR.at)}' : ''}',
        style: const TextStyle(color: AppTheme.subtitle),
      ),
      isThreeLine: lastHRV != null || lastHR != null,
    );
  }

  Widget _stat(String title, String value, String sub) => Expanded(
    child: Column(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppTheme.subtitle,
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        Text(
          sub,
          style: const TextStyle(fontSize: 10, color: AppTheme.subtitle),
        ),
      ],
    ),
  );
}
