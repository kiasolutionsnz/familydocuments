import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/security/public_https_url.dart';
import '../library/safe_open.dart';
import 'data/inbox_service.dart';
import 'inbox_navigation.dart';
import 'models/inbox_models.dart';

typedef InboxLinkOpener = Future<bool> Function(String url);

class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.service,
    required this.onDataChanged,
    required this.onOcrRequested,
    this.linkOpener,
    this.navigation,
    this.onDiscuss,
  });
  final InboxService service;
  final VoidCallback onDataChanged;
  final Future<void> Function() onOcrRequested;
  final InboxLinkOpener? linkOpener;
  final InboxNavigation? navigation;
  final ValueChanged<InboxMessage>? onDiscuss;

  @override
  State<InboxPage> createState() => InboxPageState();
}

class InboxPageState extends State<InboxPage> {
  final search = TextEditingController();
  Timer? debounce;
  InboxData? data;
  InboxMessage? message;
  InboxFilter filter = InboxFilter.all;
  bool loading = false, loadingMore = false;
  String? error;
  final Map<String, String> requestIds = {};
  late final InboxNavigation navigation;
  late final bool ownsNavigation;
  StreamSubscription<InboxLocation>? navigationSubscription;

  @override
  void initState() {
    super.initState();
    ownsNavigation = widget.navigation == null;
    navigation = widget.navigation ?? createInboxNavigation();
    navigationSubscription = navigation.changes.listen((location) {
      if (location.messageId == null) {
        if (mounted) setState(() => message = null);
      } else if (location.messageId != message?.id) {
        _open(location.messageId!, recordHistory: false);
      }
    });
    _load().then((_) {
      final id = navigation.current.messageId;
      if (id != null && mounted) _open(id, recordHistory: false);
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    navigationSubscription?.cancel();
    if (ownsNavigation) navigation.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (loading || loadingMore) return;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        error = null;
      }
    });
    try {
      final next = await widget.service.load(
        query: search.text,
        filter: filter,
        offset: more ? (data?.items.length ?? 0) : 0,
      );
      if (!mounted) return;
      if (more && data != null) {
        final items = {for (final item in data!.items) item.id: item};
        for (final item in next.items) {
          items[item.id] = item;
        }
        data = InboxData(
          canEdit: next.canEdit,
          total: next.total,
          items: items.values.toList(),
          categories: next.categories,
          tags: next.tags,
          linkCategories: next.linkCategories,
        );
      } else {
        data = next;
      }
    } on InboxServiceException catch (failure) {
      error = failure.message;
    } catch (_) {
      error = 'Inbox could not be loaded. Try again.';
    } finally {
      if (mounted) setState(() => loading = loadingMore = false);
    }
  }

  void _searchChanged(String _) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _open(String id, {bool recordHistory = true}) async {
    if (recordHistory) navigation.open(InboxLocation(messageId: id));
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await widget.service.detail(id);
      if (mounted) setState(() => message = value);
    } on InboxServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _review(String state) async {
    final current = message;
    if (current == null) return;
    try {
      await widget.service.setReviewState(current, state);
      if (!mounted) return;
      message = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state == 'reviewed' ? 'Marked reviewed.' : 'Message dismissed.',
          ),
        ),
      );
      await _load();
    } on InboxServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  String _requestId(String key) => requestIds.putIfAbsent(
    key,
    () => 'inbox-${DateTime.now().microsecondsSinceEpoch}-$key',
  );

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading Inbox'),
      );
    }
    if (data == null && error != null) {
      return _InboxState(
        message: error!,
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: ValueKey(
          message == null ? 'inbox-list' : 'inbox-detail-${message!.id}',
        ),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 96),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: message == null ? _list() : _detail(message!),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    final items = data?.items ?? const <InboxItem>[];
    final fresh = items.where((x) => x.reviewState == 'unreviewed').toList();
    final earlier = items.where((x) => x.reviewState != 'unreviewed').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: _InboxHeading(
                title: 'Inbox',
                subtitle: 'Messages waiting for your attention.',
              ),
            ),
            IconButton(
              onPressed: _load,
              tooltip: 'Refresh Inbox',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 18),
        TextField(
          controller: search,
          onChanged: _searchChanged,
          decoration: const InputDecoration(
            hintText: 'Search sender, subject or preview',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: InboxFilter.values.map((value) {
              final labels = {
                InboxFilter.all: 'All',
                InboxFilter.unreviewed: 'Unreviewed',
                InboxFilter.attachments: 'With attachments',
                InboxFilter.links: 'With links',
                InboxFilter.telegram: 'Telegram',
                InboxFilter.reviewed: 'Reviewed',
              };
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(labels[value]!),
                  selected: filter == value,
                  onSelected: (_) {
                    setState(() => filter = value);
                    _load();
                  },
                ),
              );
            }).toList(),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) _InlineError(error!, _load),
        if (items.isEmpty)
          _InboxState(
            message: search.text.trim().isNotEmpty
                ? 'Nothing matched your search.'
                : 'You’re all caught up.',
          )
        else ...[
          if (fresh.isNotEmpty) ...[
            const _GroupTitle('New'),
            ...fresh.map(_item),
          ],
          if (earlier.isNotEmpty) ...[
            const _GroupTitle('Earlier'),
            ...earlier.map(_item),
          ],
          if (items.length < (data?.total ?? 0))
            Center(
              child: TextButton(
                onPressed: loadingMore ? null : () => _load(more: true),
                child: Text(loadingMore ? 'Loading…' : 'Load more'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _item(InboxItem item) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      onTap: () => _open(item.id),
      title: Text(item.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${item.sender} · ${_date(item.receivedAt)}'),
          if (item.preview.isNotEmpty)
            Text(item.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
          Wrap(
            spacing: 10,
            children: [
              Text(item.source),
              if (item.attachmentCount > 0)
                Text(
                  '${item.attachmentCount} attachment${item.attachmentCount == 1 ? '' : 's'}',
                ),
              if (item.linkCount > 0)
                Text('${item.linkCount} link${item.linkCount == 1 ? '' : 's'}'),
              if (item.actions.isNotEmpty) const Text('Action completed'),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    ),
  );

  Widget _detail(InboxMessage value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton.icon(
        onPressed: () => navigation.open(const InboxLocation()),
        icon: const Icon(Icons.arrow_back),
        label: const Text('Back to Inbox'),
      ),
      _InboxHeading(
        title: value.subject,
        subtitle: '${value.sender} · ${_date(value.receivedAt)}',
      ),
      const SizedBox(height: 12),
      Text('To: ${value.recipients.join(', ')}'),
      Text(
        '${value.source} · ${value.reviewState == 'unreviewed' ? 'Unreviewed' : 'Reviewed'}',
      ),
      const Divider(height: 32),
      SelectableText(
        value.bodyText.isEmpty ? 'No message text.' : value.bodyText,
      ),
      if (value.attachments.isNotEmpty) ...[
        const _GroupTitle('Attachments'),
        ...value.attachments.map(
          (attachment) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.attach_file),
            title: Text(attachment.fileName),
            subtitle: Text(
              attachment.canSave ? 'Ready to save' : 'Not available yet',
            ),
            trailing: value.canEdit && attachment.canSave
                ? TextButton(
                    onPressed: () => _saveAttachment(value, attachment),
                    child: const Text('Save'),
                  )
                : null,
          ),
        ),
      ],
      if (value.links.isNotEmpty) ...[
        const _GroupTitle('Links'),
        ...value.links.map(
          (link) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(Uri.tryParse(link)?.host ?? link),
            subtitle: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Wrap(
              children: [
                IconButton(
                  tooltip: 'Open link',
                  onPressed: () => _openLink(link),
                  icon: const Icon(Icons.open_in_new),
                ),
                if (value.canEdit)
                  TextButton(
                    onPressed: () => _saveLink(value, link),
                    child: const Text('Save'),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (value.actions.isNotEmpty)
        Text('Completed: ${value.actions.join(', ')}'),
      if (error != null) _InlineError(error!, () => _open(value.id)),
      if (value.canEdit) ...[
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (widget.onDiscuss != null)
              OutlinedButton.icon(
                onPressed: () => widget.onDiscuss!(value),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Continue in Home'),
              ),
            FilledButton.icon(
              onPressed: () => _review('reviewed'),
              icon: const Icon(Icons.done),
              label: const Text('Mark reviewed'),
            ),
            OutlinedButton.icon(
              onPressed: () => _reminder(value),
              icon: const Icon(Icons.notifications_outlined),
              label: const Text('Add reminder'),
            ),
            TextButton(
              onPressed: () => _confirmDismiss(value),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ] else
        const Padding(
          padding: EdgeInsets.only(top: 20),
          child: Text(
            'You can view this message, but only authorised Family members can make changes.',
          ),
        ),
    ],
  );

  Future<void> _confirmDismiss(InboxMessage value) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dismiss this message?'),
        content: const Text(
          'It will leave the active review queue. Saved items will not be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _review('dismissed');
  }

  Future<void> _saveAttachment(
    InboxMessage parent,
    InboxAttachment attachment,
  ) async {
    final categories = [...?data?.categories];
    var category = categories.firstOrNull?.id;
    var ocr = false;
    final tags = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Save ${attachment.fileName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: categories
                    .map(
                      (x) => DropdownMenuItem(value: x.id, child: Text(x.name)),
                    )
                    .toList(),
                onChanged: (value) => setDialogState(() => category = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Create category'),
                  onPressed: () async {
                    final name = await _categoryName('Create category');
                    if (name == null) return;
                    try {
                      final created = await widget.service.createCategory(name);
                      setDialogState(() {
                        categories.add(created);
                        category = created.id;
                      });
                    } on InboxServiceException catch (failure) {
                      if (mounted) setState(() => error = failure.message);
                    }
                  },
                ),
              ),
              TextField(
                controller: tags,
                decoration: const InputDecoration(
                  labelText: 'Tags (comma separated)',
                ),
              ),
              if ((data?.tags.isNotEmpty ?? false))
                Wrap(
                  spacing: 6,
                  children: data!.tags
                      .map(
                        (tag) => ActionChip(
                          label: Text(tag),
                          onPressed: () {
                            final values = tags.text
                                .split(',')
                                .map((x) => x.trim().toLowerCase())
                                .where((x) => x.isNotEmpty)
                                .toSet();
                            values.add(tag.toLowerCase());
                            tags.text = values.join(', ');
                          },
                        ),
                      )
                      .toList(),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: ocr,
                onChanged: (value) =>
                    setDialogState(() => ocr = value ?? false),
                title: const Text('Read this document after saving'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: category == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || category == null) return;
    final key = 'attachment:${attachment.id}:${ocr ? 'ocr' : 'save'}';
    try {
      await widget.service.saveAttachment(
        messageId: parent.id,
        attachmentId: attachment.id,
        categoryId: category!,
        tags: tags.text.split(','),
        requestOcr: ocr,
        requestId: _requestId(key),
      );
      requestIds.remove(key);
      widget.onDataChanged();
      if (ocr) await widget.onOcrRequested();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ocr
                  ? 'Saved. Reading your document in the background…'
                  : 'Attachment saved.',
            ),
          ),
        );
      }
      await _open(parent.id, recordHistory: false);
    } on InboxServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      tags.dispose();
    }
  }

  Future<void> _reminder(InboxMessage parent) async {
    final title = TextEditingController(text: parent.subject);
    final date = TextEditingController();
    final time = TextEditingController();
    var recurrence = 'none';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add reminder'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: date,
                decoration: const InputDecoration(
                  labelText: 'Date (YYYY-MM-DD)',
                ),
              ),
              TextField(
                controller: time,
                decoration: const InputDecoration(
                  labelText: 'Time (HH:MM, optional)',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: recurrence,
                decoration: const InputDecoration(labelText: 'Repeat'),
                items: const [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text('Does not repeat'),
                  ),
                  DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                  DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                ],
                onChanged: (value) =>
                    setDialogState(() => recurrence = value ?? 'none'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add reminder'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      final key =
          'reminder:${parent.id}:${title.text}:${date.text}:${time.text}:$recurrence';
      try {
        await widget.service.createReminder(
          messageId: parent.id,
          title: title.text,
          date: date.text,
          time: time.text.trim().isEmpty ? null : time.text.trim(),
          recurrence: recurrence,
          requestId: _requestId(key),
        );
        requestIds.remove(key);
        widget.onDataChanged();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Reminder added.')));
        }
        await _open(parent.id, recordHistory: false);
      } on InboxServiceException catch (failure) {
        if (mounted) setState(() => error = failure.message);
      }
    }
    title.dispose();
    date.dispose();
    time.dispose();
  }

  Future<void> _saveLink(InboxMessage parent, String url) async {
    final hostname = publicHttpsHostname(url);
    if (hostname == null) {
      if (mounted) {
        setState(() => error = 'This link cannot be saved safely.');
      }
      return;
    }
    final categories = [...?data?.linkCategories];
    var category = categories.firstOrNull?.id;
    final title = TextEditingController(
      text: Uri.tryParse(url)?.host ?? 'Saved link',
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Save link'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Website: $hostname'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: categories
                    .map(
                      (x) => DropdownMenuItem(value: x.id, child: Text(x.name)),
                    )
                    .toList(),
                onChanged: (value) => setDialogState(() => category = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Create category'),
                  onPressed: () async {
                    final name = await _categoryName('Create link category');
                    if (name == null) return;
                    try {
                      final created = await widget.service.createLinkCategory(
                        name,
                      );
                      setDialogState(() {
                        categories.add(created);
                        category = created.id;
                      });
                    } on InboxServiceException catch (failure) {
                      if (mounted) setState(() => error = failure.message);
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: category == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && category != null) {
      final key = 'link:${parent.id}:$url';
      try {
        await widget.service.saveLink(
          messageId: parent.id,
          url: url,
          title: title.text,
          categoryId: category!,
          requestId: _requestId(key),
        );
        requestIds.remove(key);
        widget.onDataChanged();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Link saved.')));
        }
        await _open(parent.id, recordHistory: false);
      } on InboxServiceException catch (failure) {
        if (mounted) setState(() => error = failure.message);
      }
    }
    title.dispose();
  }

  Future<void> _openLink(String url) async {
    final hostname = publicHttpsHostname(url);
    if (hostname == null) {
      if (mounted) setState(() => error = 'This link cannot be opened safely.');
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open external website?'),
        content: Text('You are leaving FamilyDocuments for $hostname.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await (widget.linkOpener ?? openExternalLink)(url);
    }
  }

  Future<String?> _categoryName(String heading) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(heading),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result?.isEmpty == true ? null : result;
  }
}

class _InboxHeading extends StatelessWidget {
  const _InboxHeading({required this.title, required this.subtitle});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          color: Color(0xff17233a),
        ),
      ),
      const SizedBox(height: 4),
      Text(subtitle, style: const TextStyle(color: Color(0xff657083))),
    ],
  );
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 24, 0, 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );
}

class _InboxState extends StatelessWidget {
  const _InboxState({required this.message, this.action});
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 72),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Text(message), ?action],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError(this.message, this.retry);
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: ListTile(
      title: Text(message),
      trailing: TextButton(onPressed: retry, child: const Text('Retry')),
    ),
  );
}

String _date(DateTime value) =>
    '${value.day}/${value.month}/${value.year} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
