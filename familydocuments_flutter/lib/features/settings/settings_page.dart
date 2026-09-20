import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import 'drive/drive_page.dart';
import 'email/email_forwarding_page.dart';
import 'family_settings_page.dart';
import 'notifications/push_notification_page.dart';
import 'notifications/push_notification_service.dart';
import 'telegram/telegram_integration_page.dart';
import 'telegram/telegram_integration_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.auth,
    this.telegramRepository,
    this.pushRepository,
  });
  final AuthService auth;
  final TelegramIntegrationRepository? telegramRepository;
  final PushNotificationRepository? pushRepository;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Integrations', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                key: const ValueKey('email-forwarding-settings'),
                leading: const Icon(Icons.forward_to_inbox_outlined),
                title: const Text('Email forwarding and allowed senders'),
                subtitle: const Text(
                  'Manage your forwarding address and trusted sender list',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => EmailForwardingPage(auth: auth),
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Google Drive'),
              subtitle: const Text('Your Family’s document storage'),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => DrivePage(auth: auth))),
            ),
            ListTile(
              key: const ValueKey('push-notification-settings'),
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Phone reminder notifications'),
              subtitle: const Text('Control alerts and vibration on this device'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PushNotificationPage(
                    auth: auth,
                    repository: pushRepository,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Family and categories'),
              subtitle: const Text(
                'Members, invitations and document categories',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FamilySettingsPage(auth: auth),
                ),
              ),
            ),
            ListTile(
              key: const ValueKey('telegram-integration'),
              leading: const Icon(Icons.send_outlined),
              title: const Text('Telegram'),
              subtitle: const Text('Connect the FamilyDocuments bot privately'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TelegramIntegrationPage(
                    repository:
                        telegramRepository ?? TelegramIntegrationService(auth),
                  ),
                ),
              ),
            ),
            const Divider(),
          ],
        ),
      ),
    ),
  );
}
