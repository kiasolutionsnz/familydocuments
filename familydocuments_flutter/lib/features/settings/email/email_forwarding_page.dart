import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';

class EmailForwardingPage extends StatefulWidget {
  const EmailForwardingPage({super.key, required this.auth});
  final AuthService auth;
  @override
  State<EmailForwardingPage> createState() => _EmailForwardingPageState();
}

class _EmailForwardingPageState extends State<EmailForwardingPage> {
  late Future<_EmailSettings> _data = _load();
  final _sender = TextEditingController();
  bool _busy = false;
  @override
  void dispose() {
    _sender.dispose();
    super.dispose();
  }

  Future<http.Response> _rpc(String name, Map<String, dynamic> body) async {
    Future<http.Response> send() async => http.post(
      Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$name'),
      headers: {
        'authorization': 'Bearer ${await widget.auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    var response = await send();
    if (response.statusCode == 401) {
      await widget.auth.refresh();
      response = await send();
    }
    return response;
  }

  Future<_EmailSettings> _load() async {
    try {
      final snapshot = await _rpc('household_snapshot', const {});
      if (snapshot.statusCode != 200) throw StateError('snapshot unavailable');
      final rules = await _rpc('inbound_sender_rule_summaries', const {});
      final map = jsonDecode(snapshot.body) as Map;
      return _EmailSettings(
        map['inbox'] is Map ? Map.from(map['inbox'] as Map) : null,
        rules.statusCode == 200
            ? (jsonDecode(rules.body) as List? ?? const [])
                  .whereType<Map>()
                  .map(Map.from)
                  .toList()
            : const [],
      );
    } catch (_) {
      throw StateError('Email forwarding could not be loaded.');
    }
  }

  Future<void> _change(
    String rpc, [
    Map<String, dynamic> body = const {},
  ]) async {
    setState(() => _busy = true);
    try {
      final response = await _rpc(rpc, body);
      if (response.statusCode != 200) throw StateError('request failed');
      if (mounted) setState(() => _data = _load());
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That email setting could not be saved. Check your access and try again.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Email forwarding and allowed senders')),
    body: FutureBuilder<_EmailSettings>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return Center(
            child: FilledButton(
              onPressed: () => setState(() => _data = _load()),
              child: const Text('Try again'),
            ),
          );
        final data = snapshot.data!;
        final address = data.inbox?['address']?.toString();
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Forward bills, bookings and important messages to your Family Inbox.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Your forwarding address',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      address ??
                          'Email forwarding is unavailable for your role.',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Forward the original email. Attachments are held for review before they can be saved.',
                    ),
                    if (address != null)
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _change('rotate_household_inbox'),
                            child: const Text('Create a new address'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _change('disable_household_inbox'),
                            child: const Text('Disable forwarding'),
                          ),
                        ],
                      ),
                    if (address == null)
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _change('enable_household_inbox'),
                        child: const Text('Enable forwarding'),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Allowed senders',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Only allow senders you recognise. Email from anyone else remains quarantined until you approve the sender.',
            ),
            const SizedBox(height: 8),
            ...data.rules.map(
              (rule) => ListTile(
                title: Text(rule['sender_address']?.toString() ?? ''),
                subtitle: Text(rule['action']?.toString() ?? ''),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () => _change('set_inbound_sender_rule', {
                          'sender': rule['sender_address'],
                          'rule_action': 'remove',
                        }),
                  child: const Text('Remove'),
                ),
              ),
            ),
            TextField(
              controller: _sender,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Sender email address',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      final sender = _sender.text.trim();
                      if (sender.isEmpty) return;
                      _change('set_inbound_sender_rule', {
                        'sender': sender,
                        'rule_action': 'allow',
                      });
                      _sender.clear();
                    },
              child: const Text('Add allowed sender'),
            ),
          ],
        );
      },
    ),
  );
}

class _EmailSettings {
  const _EmailSettings(this.inbox, this.rules);
  final Map? inbox;
  final List<Map> rules;
}
