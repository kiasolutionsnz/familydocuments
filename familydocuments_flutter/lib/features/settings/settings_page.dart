import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import 'telegram/telegram_integration_page.dart';
import 'telegram/telegram_integration_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.auth, this.telegramRepository});
  final AuthService auth;
  final TelegramIntegrationRepository? telegramRepository;

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
            ListTile(
              key: const ValueKey('telegram-integration'),
              leading: const Icon(Icons.send_outlined),
              title: const Text('Telegram'),
              subtitle: const Text('Connect the FamilyDocuments bot'),
              trailing: const Icon(Icons.chevron_right),
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
            const ListTile(
              leading: Icon(Icons.settings_outlined),
              title: Text('More settings'),
              subtitle: Text(
                'Additional settings will be connected in a later phase.',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
