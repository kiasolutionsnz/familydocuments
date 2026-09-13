import 'package:flutter/material.dart';

import 'feedback_service.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, required this.repository});
  final FeedbackRepository repository;
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  List<FeedbackTicket>? tickets;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.repository.list();
      if (mounted) {
        setState(() {
          tickets = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Your feedback could not be loaded.');
      }
    }
  }

  Future<void> open(FeedbackTicket ticket) async {
    try {
      ticket = await widget.repository.request('detail', ticket: ticket.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Feedback could not be opened. Refresh and try again.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    var reply = '';
    var sending = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          var current = ticket;
          return AlertDialog(
            title: Text('${current.reference}: ${current.title}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(current.status),
                  const SizedBox(height: 12),
                  Text(current.data['original_feedback'] as String? ?? ''),
                  Text(current.data['latest_update'] as String? ?? ''),
                  for (final entry in current.data['replies'] as List? ?? [])
                    Text((entry as Map)['body'] as String),
                  if (current.question.isNotEmpty) Text(current.question),
                  if (['Needs clarification', 'New'].contains(current.status))
                    TextField(
                      onChanged: (value) => reply = value,
                      maxLength: 2000,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Reply to this ticket',
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              if (current.data['can_withdraw'] == true)
                TextButton(
                  onPressed: () async {
                    if (sending) {
                      return;
                    }
                    sending = true;
                    try {
                      await widget.repository.request(
                        'withdraw',
                        ticket: current.id,
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    } catch (_) {
                      sending = false;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not withdraw. Try again.'),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Withdraw'),
                ),
              if (['Needs clarification', 'New'].contains(current.status))
                FilledButton(
                  onPressed: () async {
                    if (sending || reply.trim().isEmpty) {
                      return;
                    }
                    sending = true;
                    try {
                      await widget.repository.request(
                        'reply',
                        ticket: current.id,
                        message: reply.trim(),
                      );
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    } catch (_) {
                      sending = false;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Reply was not saved. Try again.'),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('Send reply'),
                ),
            ],
          );
        },
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('My feedback'),
      actions: [
        IconButton(
          tooltip: 'Refresh feedback',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  TextButton(onPressed: load, child: const Text('Retry')),
                ],
              )
            : tickets == null
            ? const CircularProgressIndicator()
            : tickets!.isEmpty
            ? const Text('No feedback yet. Say “Feedback: …” in Home.')
            : ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Private to you. Tested changes are not released until deployment is verified.',
                    ),
                  ),
                  for (final ticket in tickets!)
                    ListTile(
                      title: Text('${ticket.reference}: ${ticket.title}'),
                      subtitle: Text(
                        '${ticket.status}\n${ticket.data['latest_update'] ?? ''}',
                      ),
                      isThreeLine: true,
                      onTap: () => open(ticket),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                ],
              ),
      ),
    ),
  );
}
