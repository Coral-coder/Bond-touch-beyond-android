import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_model.dart';
import 'theme.dart';

/// First launch: sign in to your Bond Touch account (email link, as in the official app),
/// then your name and colour.
class Onboarding extends StatefulWidget {
  const Onboarding({super.key, required this.model});
  final AppModel model;
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  late final _email = TextEditingController(text: widget.model.email);
  final _link = TextEditingController();
  late final _name = TextEditingController(text: widget.model.name);
  late int _color = widget.model.colorRGB;
  bool _linkSent = false, _busy = false;
  String? _error;

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
  Widget build(BuildContext context) {
    final m = widget.model;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),
            const Text(
              'Bond Touch Beyond',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              'Touches across the distance, with your Bond Touch bracelet and your partners.',
              style: TextStyle(color: AppTheme.subtitle),
            ),
            const SizedBox(height: 32),
            if (!m.signedIn) ..._signIn() else ..._profile(),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _signIn() => [
    const Text(
      'Sign in with your Bond Touch account',
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Email',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: _busy
          ? null
          : () => _run(() async {
              await widget.model.sendSignInLink(_email.text);
              setState(() => _linkSent = true);
            }),
      child: Text(
        _linkSent ? 'Send the link again' : 'Email me a sign-in link',
      ),
    ),
    if (_linkSent) ...[
      const SizedBox(height: 20),
      const Text(
        'Open the email from Bond Touch, long-press the sign-in link, copy it, and paste it here.',
        style: TextStyle(color: AppTheme.subtitle),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _link,
        decoration: InputDecoration(
          labelText: 'Sign-in link',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.content_paste),
            tooltip: 'Paste',
            onPressed: () async {
              final clip = await Clipboard.getData(Clipboard.kTextPlain);
              if (clip?.text != null) _link.text = clip!.text!;
            },
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(() async {
                await widget.model.completeSignIn(_link.text);
                _name.text = widget.model.name;
                setState(() => _color = widget.model.colorRGB);
              }),
        child: const Text('Sign in'),
      ),
    ],
  ];

  List<Widget> _profile() => [
    TextField(
      controller: _name,
      maxLength: 25,
      decoration: const InputDecoration(
        labelText: 'Your name',
        border: OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 16),
    const Text('Your colour', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 10),
    ColorRow(selected: _color, onPick: (c) => setState(() => _color = c)),
    const SizedBox(height: 32),
    FilledButton(
      onPressed: _name.text.trim().isEmpty
          ? null
          : () => widget.model.saveProfile(name: _name.text, colorRGB: _color),
      child: const Padding(
        padding: EdgeInsets.all(14),
        child: Text('Continue'),
      ),
    ),
  ];
}

class ColorRow extends StatelessWidget {
  const ColorRow({super.key, required this.selected, required this.onPick});
  final int selected;
  final void Function(int) onPick;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final c in AppTheme.palette)
        GestureDetector(
          onTap: () => onPick(c),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.rgb(c),
              shape: BoxShape.circle,
              border: Border.all(
                color: c == selected ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
          ),
        ),
    ],
  );
}
