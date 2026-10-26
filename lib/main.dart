import 'dart:async';

import 'package:flutter/material.dart';

import 'app/app_model.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final model = AppModel();
  runApp(BondApp(model: model));
  unawaited(model.start());
}

class BondApp extends StatefulWidget {
  const BondApp({super.key, required this.model});
  final AppModel model;
  @override
  State<BondApp> createState() => _BondAppState();
}

class _BondAppState extends State<BondApp> {
  late final AppLifecycleListener _life;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onResume: () => widget.model.setForeground(true),
      onPause: () => widget.model.setForeground(false),
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bond Touch Beyond',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.data,
    scaffoldMessengerKey: _messenger,
    home: ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => widget.model.profileComplete
          ? HomeShell(model: widget.model)
          : Onboarding(model: widget.model),
    ),
  );
}
