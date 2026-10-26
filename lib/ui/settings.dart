import 'package:flutter/material.dart';

import '../app/app_model.dart';
import 'onboarding.dart';
import 'pairing.dart';
import 'theme.dart';

/// Profile, bracelet, sharing, partners and the Bond Touch account.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Glass(
          child: Row(
            children: [
              Avatar(
                name: model.name,
                color: model.colorRGB,
                photo: model.myPhoto,
                size: 56,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  model.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _editProfile(context),
                child: const Text('Edit'),
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
                'Bracelet',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                _braceletText(),
                style: const TextStyle(color: AppTheme.subtitle),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: () => model.bracelet.scanAndConnect(),
                    child: Text(
                      model.bracelet.isReady ? 'Reconnect' : 'Find my bracelet',
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (model.bracelet.isReady)
                    OutlinedButton(
                      onPressed: () => model.bracelet.forget(),
                      child: const Text('Forget'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Glass(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                value: model.sharingLocation,
                onChanged: model.setLocationSharing,
                title: const Text('Share my location'),
                subtitle: const Text(
                  'Your partners see where you are and how far apart you are.',
                ),
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
                'Partners',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              for (final p in model.partners)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Avatar(
                    name: p.name,
                    color: p.colorRGB,
                    photo: p.photo,
                    size: 36,
                    online: p.online,
                  ),
                  title: Text(p.name),
                  trailing: model.selected?.id == p.id
                      ? const Icon(Icons.check, color: AppTheme.accent)
                      : null,
                  onTap: () => model.select(p.id),
                ),
              for (final b in model.sentInvites)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.hourglass_top),
                  title: Text(b.email.isEmpty ? b.partnerName : b.email),
                  subtitle: const Text('Waiting for them to accept'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => model.removeBond(b),
                  ),
                ),
              TextButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text('Add a partner'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => PairingPage(model: model)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Glass(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bond Touch account',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      model.email,
                      style: const TextStyle(color: AppTheme.subtitle),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: model.signOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _braceletText() {
    final b = model.bracelet;
    if (b.isReady) {
      return 'Connected${b.batteryPercent != null ? ' · ${b.batteryPercent}%' : ''}';
    }
    return switch (b.state.name) {
      'bluetoothOff' => 'Bluetooth is off',
      'scanning' => 'Looking for your bracelet…',
      'connecting' => 'Connecting…',
      _ => 'Not connected',
    };
  }

  void _editProfile(BuildContext context) {
    final name = TextEditingController(text: model.name);
    var color = model.colorRGB;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(c).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                maxLength: 25,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              ColorRow(selected: color, onPick: (v) => set(() => color = v)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  model.saveProfile(name: name.text, colorRGB: color);
                  Navigator.pop(c);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
