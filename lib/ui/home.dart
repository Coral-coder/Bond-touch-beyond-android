import 'package:flutter/material.dart';

import '../app/app_model.dart';
import '../models/presence.dart';
import '../models/touch_message.dart';
import 'charts.dart';
import 'chat.dart';
import 'pairing.dart';
import 'partner_detail.dart';
import 'settings.dart';
import 'stress_mood.dart';
import 'theme.dart';
import 'touch_pad.dart';

/// Home, Chat, Stress & mood and Settings.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model});
  final AppModel model;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    final pages = [
      HomePage(model: m),
      ChatPage(model: m),
      StressMoodPage(model: m),
      SettingsPage(model: m),
    ];
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.bgTop, AppTheme.bgBottom],
          ),
        ),
        child: SafeArea(bottom: false, child: pages[_tab]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_rounded),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_rounded),
            label: 'Stress & mood',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final partner = model.selected;
      if (model.firebaseError != null) {
        return _Banner(
          'Partners need Firebase, which isn\'t set up in this build yet.\n${model.firebaseError}',
        );
      }
      if (partner == null) return NoPartner(model: model);
      final history = model.history
          .where((t) => t.bondID == partner.id)
          .toList()
          .reversed
          .take(50)
          .toList();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (model.partners.length > 1)
            SizedBox(
              height: 64,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final p in model.partners)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: GestureDetector(
                        onTap: () => model.select(p.id),
                        child: Opacity(
                          opacity: p.id == partner.id ? 1 : 0.5,
                          child: Avatar(
                            name: p.name,
                            color: p.colorRGB,
                            photo: p.photo,
                            size: 52,
                            online: p.online,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PartnerDetail(model: model, partner: partner),
              ),
            ),
            child: Glass(
              child: Row(
                children: [
                  Avatar(
                    name: model.name,
                    color: model.colorRGB,
                    photo: model.myPhoto,
                    size: 56,
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.favorite, color: AppTheme.accent, size: 18),
                  const SizedBox(width: 8),
                  Avatar(
                    name: partner.name,
                    color: partner.colorRGB,
                    photo: partner.photo,
                    size: 56,
                    online: partner.online,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          partner.name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          _statusLine(partner),
                          style: const TextStyle(
                            color: AppTheme.subtitle,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (partner.presence?.mood case final MoodShare mood)
                    Text(
                      mood.emoji.isEmpty
                          ? MoodShare.face(mood.stress).emoji
                          : mood.emoji,
                      style: const TextStyle(fontSize: 30),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Glass(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Send ${partner.name} a touch',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                TouchPad(
                  color: model.colorRGB,
                  onSend: (samples) =>
                      model.sendTouch(pattern: samples, generation: 3),
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
                  'Touches',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                if (history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No touches yet',
                      style: TextStyle(color: AppTheme.subtitle),
                    ),
                  ),
                for (final t in history)
                  _TouchRow(t: t, model: model, partnerName: partner.name),
              ],
            ),
          ),
        ],
      );
    },
  );

  String _statusLine(Partner p) {
    final pr = p.presence;
    if (pr == null) return 'Waiting for their first update';
    final parts = <String>[p.online ? 'Online' : 'Seen ${agoText(pr.sentAt)}'];
    if (pr.bracelet == true) parts.add('bracelet on');
    return parts.join(' · ');
  }
}

class _TouchRow extends StatelessWidget {
  const _TouchRow({
    required this.t,
    required this.model,
    required this.partnerName,
  });
  final TouchMessage t;
  final AppModel model;
  final String partnerName;
  @override
  Widget build(BuildContext context) {
    final mine = t.senderID == 'me';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [AppTheme.rgb(t.colorRGB), AppTheme.rgb(t.endColorRGB)],
          ),
        ),
        child: Icon(
          t.isHeartbeat ? Icons.favorite : Icons.touch_app,
          size: 18,
          color: Colors.white,
        ),
      ),
      title: Text(
        t.isHeartbeat
            ? 'Heartbeat · ${t.heartbeatBPM} BPM'
            : t.meaningLabel != null
            ? '${t.meaningEmoji ?? ''} ${t.meaningLabel}'
            : (mine ? 'You sent a touch' : '$partnerName sent a touch'),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        whenText(context, t.sentAt),
        style: const TextStyle(color: AppTheme.subtitle, fontSize: 12),
      ),
      trailing: mine
          ? null
          : IconButton(
              icon: const Icon(Icons.replay),
              tooltip: 'Play again',
              onPressed: () => model.bracelet.play(t),
            ),
    );
  }
}

class NoPartner extends StatelessWidget {
  const NoPartner({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 40),
      const Icon(Icons.favorite_border, size: 64, color: AppTheme.accent),
      const SizedBox(height: 16),
      const Text(
        'Add your partner',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      const Text(
        'Send them an invite link, or enter the code they sent you. Works with partners on iPhone too.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.subtitle),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        icon: const Icon(Icons.person_add),
        label: const Text('Invite or join'),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => PairingPage(model: model))),
      ),
      if (model.pending.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text(
            'Invite sent — waiting for your partner to join.',
            textAlign: TextAlign.center,
          ),
        ),
    ],
  );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Glass(child: Text(text)),
  );
}
