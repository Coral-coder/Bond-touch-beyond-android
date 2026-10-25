import 'package:flutter/material.dart';

import '../app/app_model.dart';
import 'theme.dart';

/// First launch: your name and colour (how you show up for partners and on the bracelet).
class Onboarding extends StatefulWidget {
  const Onboarding({super.key, required this.model});
  final AppModel model;
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final _name = TextEditingController();
  int _color = AppTheme.palette.first;

  @override
  Widget build(BuildContext context) => Scaffold(
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
            'Touches across the distance — with your bracelet, your phone and your partners.',
            style: TextStyle(color: AppTheme.subtitle),
          ),
          const SizedBox(height: 32),
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
          const Text(
            'Your colour',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          ColorRow(selected: _color, onPick: (c) => setState(() => _color = c)),
          const SizedBox(height: 32),
          FilledButton(
            onPressed: _name.text.trim().isEmpty
                ? null
                : () => widget.model.saveProfile(
                    name: _name.text,
                    colorRGB: _color,
                  ),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Continue'),
            ),
          ),
        ],
      ),
    ),
  );
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
