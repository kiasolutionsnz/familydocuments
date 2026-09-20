import 'package:flutter/material.dart';

import '../../../core/auth/auth_service.dart';
import 'push_notification_service.dart';

class PushNotificationPage extends StatefulWidget {
  const PushNotificationPage({super.key, required this.auth, this.repository});
  final AuthService auth;
  final PushNotificationRepository? repository;

  @override
  State<PushNotificationPage> createState() => _PushNotificationPageState();
}

class _PushNotificationPageState extends State<PushNotificationPage> {
  late final PushNotificationRepository service =
      widget.repository ?? PushNotificationService(widget.auth);
  bool loading = true, busy = false, enabled = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      enabled = await service.loadEnabled();
    } catch (_) {
      error = 'Notification settings could not be loaded. Try again.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _change(bool value) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      if (value) {
        await service.enable();
      } else {
        await service.disable();
      }
      if (mounted) setState(() => enabled = value);
    } on PushNotificationException catch (exception) {
      if (mounted) setState(() => error = exception.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Notification settings could not be changed.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Phone reminders')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Get a notification and vibration on this phone when a reminder is due.'),
            const SizedBox(height: 16),
            if (loading || busy) const LinearProgressIndicator(),
            if (!service.supported)
              const Text('Phone reminders are available in the Android and iPhone apps.'),
            if (service.supported && !service.configured)
              const Text('Phone reminders are not configured in this app build.'),
            SwitchListTile(
              key: const ValueKey('push-reminders-toggle'),
              value: enabled,
              onChanged: loading || busy || !service.supported || !service.configured ? null : _change,
              title: const Text('Push reminder notifications'),
              subtitle: const Text('Email reminders remain controlled separately.'),
            ),
            if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            const Text('Only reminders addressed to you are sent to this device. You can turn this off at any time.'),
          ],
        ),
      ),
    ),
  );
}
