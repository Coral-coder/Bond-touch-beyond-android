import 'package:flutter/material.dart';

import '../app/updater.dart';
import 'theme.dart';

/// Offers a newer GitHub release and shows the download; see [Updater].
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.release});
  final ReleaseInfo release;

  /// Shows the prompt for [release] on top of whatever is on screen.
  static Future<void> show(BuildContext context, ReleaseInfo release) =>
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdateDialog(release: release),
      );

  @override
  Widget build(BuildContext context) {
    final u = Updater.shared;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${release.label} is out. You have ${u.installedVersion} (build ${u.installedCode}).',
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                release.notes,
                style: const TextStyle(color: AppTheme.subtitle),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (u.downloading) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: u.progress, minHeight: 8),
              const SizedBox(height: 6),
              Text('Downloading ${(u.progress * 100).round()}%'),
            ] else if (u.downloaded != null) ...[
              const SizedBox(height: 8),
              const Text('Downloaded and ready to install.'),
            ],
            if (u.error != null) ...[
              const SizedBox(height: 10),
              Text(u.error!, style: const TextStyle(color: AppTheme.danger)),
            ],
          ],
        ),
        actions: [
          if (!u.downloading)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Later'),
            ),
          if (!u.downloading &&
              u.error != null &&
              u.error!.contains('different key'))
            TextButton(
              onPressed: u.installAnyway,
              child: const Text('Open installer anyway'),
            ),
          if (!u.downloading)
            FilledButton.icon(
              icon: const Icon(Icons.system_update),
              label: Text(
                u.downloaded != null ? 'Install' : 'Download & install',
              ),
              onPressed: () async {
                final ok = await u.downloadAndInstall(release: release);
                if (ok && context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}

/// Checks GitHub on launch and whenever the app returns to the foreground, and shows
/// [UpdateDialog] when a newer build exists. Wrap the first screen with it; it draws nothing.
class UpdateCheck extends StatefulWidget {
  const UpdateCheck({super.key, required this.child});
  final Widget child;
  @override
  State<UpdateCheck> createState() => _UpdateCheckState();
}

class _UpdateCheckState extends State<UpdateCheck> with WidgetsBindingObserver {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final u = Updater.shared;
    final already = u.available;
    final release = await u.checkAutomatically();
    // Prompt once per build found; a resume that finds the same build stays quiet.
    if (release == null ||
        !mounted ||
        _showing ||
        (already != null && already.versionCode == release.versionCode)) {
      return;
    }
    _showing = true;
    await UpdateDialog.show(context, release);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
