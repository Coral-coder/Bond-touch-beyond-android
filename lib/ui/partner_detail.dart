import 'dart:math';

import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../models/presence.dart';
import 'charts.dart';
import 'theme.dart';

/// A partner's page: their status (phone, bracelet, last check-in, location), how they're
/// feeling, and their stress, HRV and heart rate — each the last report, with its time.
class PartnerDetail extends StatelessWidget {
  const PartnerDetail({super.key, required this.model, required this.partner});
  final AppModel model;
  final Partner partner;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final p = partner.presence;
      final mood = p?.mood;
      return Scaffold(
        appBar: AppBar(title: Text(partner.name)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: Avatar(
                name: partner.name,
                color: partner.colorRGB,
                photo: partner.photo,
                size: 96,
                online: partner.online,
              ),
            ),
            const SizedBox(height: 16),
            Glass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'STATUS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.subtitle,
                      letterSpacing: 1.2,
                    ),
                  ),
                  _row(
                    Icons.battery_std,
                    'Phone',
                    p?.phoneBattery == null
                        ? '—'
                        : '${(p!.phoneBattery! * 100).round()}%${p.phoneCharging == true ? ' · charging' : ''}',
                  ),
                  _row(
                    Icons.watch,
                    'Bracelet',
                    p == null
                        ? '—'
                        : p.bracelet == true
                        ? 'Connected${p.braceletBattery != null ? ' · ${p.braceletBattery}%' : ''}'
                        : p.braceletLastConnected != null
                        ? 'Last connected ${agoText(p.braceletLastConnected!)}'
                        : 'Not connected',
                  ),
                  _row(
                    Icons.schedule,
                    'Last check-in',
                    p == null
                        ? '—'
                        : (partner.online ? 'Online now' : agoText(p.sentAt)),
                  ),
                  _row(
                    Icons.location_on,
                    'Location update',
                    p?.locationAt == null
                        ? 'None yet'
                        : agoText(p!.locationAt!),
                  ),
                  if (p?.lat != null && model.location.last != null)
                    _row(
                      Icons.straighten,
                      'Distance',
                      _distance(
                        model.location.last!.latitude,
                        model.location.last!.longitude,
                        p!.lat!,
                        p.lng!,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Glass(
              child: Row(
                children: [
                  Text(
                    mood == null
                        ? '🫥'
                        : (mood.emoji.isEmpty
                              ? MoodShare.face(mood.stress).emoji
                              : mood.emoji),
                    style: const TextStyle(fontSize: 40),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mood == null
                              ? 'No mood reported yet'
                              : (mood.label.isEmpty
                                    ? MoodShare.face(mood.stress).label
                                    : mood.label),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (mood != null)
                          Text(
                            'Stress ${mood.stress} / 100 · ${whenText(context, mood.at)}',
                            style: const TextStyle(color: AppTheme.subtitle),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            HealthCharts(
              series: mood?.series ?? const [],
              heartRate: mood?.heartRate ?? const [],
              emptyText: 'No Health readings from ${partner.name} yet.',
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off, color: AppTheme.danger),
              label: const Text(
                'Remove partner',
                style: TextStyle(color: AppTheme.danger),
              ),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text('Remove ${partner.name}?'),
                    content: const Text(
                      'You stop sending each other touches. You can invite them again any time.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await model.removePartner(partner.bond);
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
      );
    },
  );

  Widget _row(IconData icon, String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.accent),
        const SizedBox(width: 12),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(value, style: const TextStyle(color: AppTheme.subtitle)),
      ],
    ),
  );

  static String _distance(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    double rad(double d) => d * pi / 180;
    final a =
        pow(sin(rad(lat2 - lat1) / 2), 2) +
        cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(rad(lng2 - lng1) / 2), 2);
    final km = 2 * r * asin(sqrt(a));
    return km < 1
        ? '${(km * 1000).round()} m'
        : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';
  }
}
