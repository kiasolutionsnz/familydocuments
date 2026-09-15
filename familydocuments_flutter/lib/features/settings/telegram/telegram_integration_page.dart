import 'package:flutter/material.dart';

import '../../../core/auth/auth_service.dart';
import '../../library/safe_open.dart';
import 'telegram_integration_service.dart';

class TelegramIntegrationPage extends StatefulWidget {
  const TelegramIntegrationPage({super.key, required this.repository});
  final TelegramIntegrationRepository repository;

  @override
  State<TelegramIntegrationPage> createState() =>
      _TelegramIntegrationPageState();
}

class _TelegramIntegrationPageState extends State<TelegramIntegrationPage> {
  TelegramConnection? connection;
  TelegramConnectLink? link;
  String? error;
  bool loading = true, changing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.repository.status();
      if (mounted) setState(() => connection = value);
    } on AuthException {
      if (mounted) {
        setState(
          () => error = 'Your session has expired. Please sign in again.',
        );
      }
    } on TelegramIntegrationException catch (failure) {
      if (mounted) {
        setState(() => error = failure.message);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _connect() async {
    final familyId = connection?.familyId;
    if (familyId == null || changing) return;
    setState(() {
      changing = true;
      error = null;
    });
    try {
      final value = await widget.repository.connect(familyId);
      if (mounted) setState(() => link = value);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'A connection link could not be created.');
      }
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  Future<void> _disconnect() async {
    final familyId = connection?.familyId;
    if (familyId == null || changing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Telegram?'),
        content: const Text(
          'New Telegram messages will no longer be processed. Saved FamilyDocuments information will remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => changing = true);
    try {
      await widget.repository.disconnect(familyId);
      link = null;
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Telegram could not be disconnected.');
      }
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Telegram')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null && connection == null
              ? _MessageState(message: error!, onRetry: _load)
              : _content(),
        ),
      ),
    ),
  );

  Widget _content() {
    final value = connection!;
    if (value.selectionRequired) {
      return const _MessageState(
        message: 'Choose an active Family before connecting Telegram.',
      );
    }
    if (!value.available) {
      return const _MessageState(
        message:
            'Telegram setup is not complete for this staging environment yet.',
      );
    }
    if (value.state == TelegramConnectionState.membershipRevoked) {
      return const _MessageState(
        message:
            'Your Family access changed. Reconnect after resolving access.',
      );
    }
    final pending = value.state == TelegramConnectionState.linkPending;
    final disconnected = value.state == TelegramConnectionState.disconnected;
    return ListView(
      children: [
        Text('Telegram', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('Use the FamilyDocuments bot in a private Telegram chat.'),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(child: Icon(Icons.send_outlined)),
          title: Text(
            value.connected
                ? (value.displayName?.isNotEmpty == true
                      ? value.displayName!
                      : 'Connected account')
                : pending
                ? 'Link pending'
                : disconnected
                ? 'Disconnected'
                : 'Not connected',
          ),
          subtitle: Text(
            'Family: ${value.familyName ?? 'Family'}${value.username?.isNotEmpty == true ? '\n@${value.username}' : ''}',
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (link != null) ...[
          const SizedBox(height: 16),
          const Text('This private connection link expires in 10 minutes.'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: changing ? null : () => openExternalLink(link!.url),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open Telegram'),
          ),
          TextButton(
            onPressed: changing ? null : _connect,
            child: const Text('Generate a new link'),
          ),
        ] else if (pending) ...[
          const SizedBox(height: 16),
          Text(
            value.linkExpiresAt == null
                ? 'Your connection link is pending.'
                : 'Connection link expires ${_friendlyExpiry(value.linkExpiresAt!)}.',
          ),
          TextButton(
            onPressed: changing ? null : _connect,
            child: const Text('Generate a new link'),
          ),
        ] else if (value.connected)
          OutlinedButton(
            onPressed: changing ? null : _disconnect,
            child: const Text('Disconnect'),
          )
        else
          FilledButton(
            onPressed: changing ? null : _connect,
            child: Text(
              changing
                  ? 'Creating link…'
                  : disconnected
                  ? 'Reconnect Telegram'
                  : 'Connect Telegram',
            ),
          ),
      ],
    );
  }

  String _friendlyExpiry(DateTime value) {
    final local = value.toLocal();
    final minute = local.minute.toString().padLeft(2, '0');
    return 'at ${local.hour}:$minute';
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
