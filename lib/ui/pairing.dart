import 'package:flutter/material.dart';

import '../app/app_model.dart';
import 'theme.dart';

/// Invite a partner by their Bond Touch account email, and answer invites sent to you.
class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.model});
  final AppModel model;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _email = TextEditingController();
  String? _error, _done;
  bool _busy = false;

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      await job();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final m = widget.model;
      return Scaffold(
        appBar: AppBar(title: const Text('Add a partner')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (m.receivedInvites.isNotEmpty) ...[
              Glass(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Invites for you',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    for (final b in m.receivedInvites)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(b.partnerName),
                        subtitle: b.email.isEmpty ? null : Text(b.email),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Decline',
                              onPressed: _busy
                                  ? null
                                  : () => _run(() => m.removeBond(b)),
                            ),
                            FilledButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(() async {
                                      await m.accept(b);
                                      if (context.mounted) {
                                        Navigator.of(context).pop();
                                      }
                                    }),
                              child: const Text('Accept'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            Glass(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Invite',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Enter the email of your partner\'s Bond Touch account. They accept in their app (any Bond Touch app).',
                    style: TextStyle(color: AppTheme.subtitle),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Their email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await m.invite(_email.text);
                            _email.clear();
                            setState(() => _done = 'Invite sent.');
                          }),
                    child: const Text('Send invite'),
                  ),
                  for (final b in m.sentInvites)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hourglass_top),
                      title: Text(b.email.isEmpty ? b.partnerName : b.email),
                      subtitle: const Text('Waiting for them to accept'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Cancel invite',
                        onPressed: _busy
                            ? null
                            : () => _run(() => m.removeBond(b)),
                      ),
                    ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_done != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(_done!)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.danger),
                ),
              ),
          ],
        ),
      );
    },
  );
}
