import 'package:flutter/material.dart';

import 'data/reminder_service.dart';
import 'models/reminder_models.dart';

class RemindersPage extends StatefulWidget {
  const RemindersPage({
    super.key,
    required this.service,
    this.onAddToList,
    this.refreshRevision = 0,
  });
  final ReminderService service;
  final ValueChanged<ReminderItem>? onAddToList;
  final int refreshRevision;
  @override
  State<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends State<RemindersPage> {
  late Future<ReminderDashboard> _dashboard = widget.service.load();
  String _filter = 'upcoming';
  String? _workingId;
  bool _updatingDelivery = false;
  DateTime? _lastLoadedAt;

  @override
  void didUpdateWidget(covariant RemindersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshRevision != oldWidget.refreshRevision) {
      _reload();
    }
  }

  Future<void> _reload() async {
    setState(() {
      _dashboard = widget.service.load();
    });
    // FutureBuilder owns load errors, including retries and refresh after edits.
    try {
      await _dashboard;
      if (mounted) setState(() => _lastLoadedAt = DateTime.now());
    } catch (_) {}
  }

  List<ReminderItem> _items(ReminderDashboard data) => data.items.where((item) {
    if (_filter == 'completed') return item.status == 'completed';
    if (_filter == 'overdue') return item.active && item.dueState == 'overdue';
    return item.active && item.dueState != 'overdue';
  }).toList();

  Future<void> _run(ReminderItem item, Future<void> Function() action) async {
    setState(() => _workingId = item.id);
    try {
      await action();
      if (mounted) await _reload();
    } on ReminderServiceException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _workingId = null);
    }
  }

  Future<void> _snooze(ReminderItem item) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().add(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now().add(const Duration(days: 7)),
    );
    if (date == null || !mounted) return;
    await _run(
      item,
      () =>
          widget.service.act(item.id, 'snooze', snoozeUntil: _dateValue(date)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<ReminderDashboard>(
      future: _dashboard,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Reminders could not be loaded.'),
                FilledButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        final items = _items(snapshot.data!);
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Every reminder, in one place.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                _lastLoadedAt == null
                    ? 'Up to date'
                    : 'Updated ${TimeOfDay.fromDateTime(_lastLoadedAt!).format(context)}',
                key: const ValueKey('reminders-last-updated'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Card(
                child: SwitchListTile(
                  title: const Text('Reminder emails'),
                  subtitle: const Text(
                    'Email is the only delivery channel. This changes only your own delivery preference.',
                  ),
                  value: snapshot.data!.emailEnabled,
                  onChanged: _updatingDelivery
                      ? null
                      : (enabled) async {
                          setState(() => _updatingDelivery = true);
                          try {
                            await widget.service.setEmailDelivery(enabled);
                            if (mounted) await _reload();
                          } on ReminderServiceException catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(error.message)),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _updatingDelivery = false);
                            }
                          }
                        },
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'upcoming', label: Text('Upcoming')),
                  ButtonSegment(value: 'overdue', label: Text('Overdue')),
                  ButtonSegment(value: 'completed', label: Text('Completed')),
                ],
                selected: {_filter},
                onSelectionChanged: (value) =>
                    setState(() => _filter = value.first),
              ),
              const SizedBox(height: 16),
              if (items.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing here right now. Add a reminder when you save or review a document.',
                    ),
                  ),
                ),
              ...items.map(_card),
              if (snapshot.data!.deliveryHistory.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Recent email delivery',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                ...snapshot.data!.deliveryHistory.map(
                  (delivery) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(delivery.subject),
                    subtitle: Text(
                      [
                        delivery.status,
                        delivery.sentAt == null
                            ? 'Queued ${MaterialLocalizations.of(context).formatMediumDate(delivery.createdAt)}'
                            : 'Sent ${MaterialLocalizations.of(context).formatMediumDate(delivery.sentAt!)}',
                      ].join(' · '),
                    ),
                    trailing: _DeliveryStatus(status: delivery.status),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  );

  Widget _card(ReminderItem item) {
    final working = _workingId == item.id;
    final subtitle = [
      item.categoryName,
            _dueLabel(item),
      if (item.dueTime != null) item.dueTime,
      if (item.recurrence != 'none') item.recurrence,
      item.audience == 'family' ? 'Family' : 'Personal',
    ].whereType<String>().join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (item.dueState == 'overdue')
                  const Chip(label: Text('Overdue')),
              ],
            ),
            if (item.documentTitle != null)
              Text(
                item.documentTitle!,
                style: const TextStyle(color: Color(0xff64748b)),
              ),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Color(0xff64748b))),
            if (item.active) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: working
                        ? null
                        : () => _run(
                            item,
                            () => widget.service.act(item.id, 'complete'),
                          ),
                    child: const Text('Complete'),
                  ),
                  OutlinedButton(
                    onPressed: working ? null : () => _snooze(item),
                    child: const Text('Snooze'),
                  ),
                  if (widget.onAddToList != null)
                    OutlinedButton(
                      onPressed: working
                          ? null
                          : () => widget.onAddToList!(item),
                      child: const Text('Add to shared list'),
                    ),
                  PopupMenuButton<String>(
                    enabled: !working,
                    onSelected: (value) => _run(
                      item,
                      () => widget.service.configure(item.id, value),
                    ),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'none',
                        child: Text('Does not repeat'),
                      ),
                      PopupMenuItem(
                        value: 'monthly',
                        child: Text('Repeat monthly'),
                      ),
                      PopupMenuItem(
                        value: 'yearly',
                        child: Text('Repeat yearly'),
                      ),
                    ],
                    child: const Chip(label: Text('Repeat')),
                  ),
                  PopupMenuButton<String>(
                    enabled: !working,
                    onSelected: (value) => _run(
                      item,
                      () => widget.service.setAudience(item.id, value),
                    ),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'personal', child: Text('Only me')),
                      PopupMenuItem(
                        value: 'family',
                        child: Text('Share with family'),
                      ),
                    ],
                    child: const Chip(label: Text('Sharing')),
                  ),
                  TextButton(
                    onPressed: working
                        ? null
                        : () => _run(
                            item,
                            () => widget.service.act(item.id, 'dismiss'),
                          ),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _dueLabel(ReminderItem item) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = DateTime(item.dueAt.year, item.dueAt.month, item.dueAt.day);
    final days = due.difference(today).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    return MaterialLocalizations.of(context).formatMediumDate(item.dueAt);
  }
}

String _dateValue(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class _DeliveryStatus extends StatelessWidget {
  const _DeliveryStatus({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final lower = status.toLowerCase();
    final color = lower == 'sent'
        ? Colors.green
        : lower.contains('fail') || lower.contains('dead')
        ? Colors.red
        : Colors.orange;
    return Chip(
      label: Text(status),
      avatar: Icon(Icons.circle, size: 10, color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}
