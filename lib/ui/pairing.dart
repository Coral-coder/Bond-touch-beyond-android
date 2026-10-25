import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_model.dart';
import 'theme.dart';

/// Invite a partner (a link to send them) or join with their link or code.
class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.model});
  final AppModel model;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _code = TextEditingController();
  String? _link;
  String? _error;
  bool _busy = false;

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add a partner')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                'Make a link and send it to your partner. When they open it (Android or iPhone), you\'re connected.',
                style: TextStyle(color: AppTheme.subtitle),
              ),
              const SizedBox(height: 12),
              if (_link == null)
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final link = await widget.model.createInvite();
                          setState(() => _link = link);
                        }),
                  child: const Text('Make an invite link'),
                )
              else ...[
                SelectableText(
                  _link!,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                      onPressed: () => SharePlus.instance.share(
                        ShareParams(
                          text: 'Connect with me on Bond Touch Beyond: $_link',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: _link!)),
                      child: const Text('Copy'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Glass(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Join',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Invite link or code',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await widget.model.join(_code.text);
                        if (context.mounted) Navigator.of(context).pop();
                      }),
                child: const Text('Join'),
              ),
            ],
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
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
}
