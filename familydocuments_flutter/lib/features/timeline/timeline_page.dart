import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/home/home_service.dart';
import 'data/timeline_service.dart';
import 'models/timeline_item.dart';

enum TimelineFilter { all, documents, links, messages, reminders }

class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    required this.service,
    required this.processingJobs,
    required this.onRefreshProcessing,
    required this.onRetryJob,
    required this.onSaveWithoutReading,
    required this.onChooseCategory,
    required this.onDismissJob,
    this.onOpenDocument,
  });

  final TimelineService service;
  final List<AnalysisJob> processingJobs;
  final Future<void> Function() onRefreshProcessing;
  final Future<void> Function(String) onRetryJob;
  final Future<void> Function(String) onSaveWithoutReading;
  final Future<void> Function(String) onChooseCategory;
  final Future<void> Function(String) onDismissJob;
  final Future<void> Function(String)? onOpenDocument;

  @override
  State<TimelinePage> createState() => TimelinePageState();
}

class TimelinePageState extends State<TimelinePage> {
  final search = TextEditingController();
  Timer? debounce;
  TimelineFilter filter = TimelineFilter.all;
  List<TimelineItem> items = const [];
  TimelineCursor? cursor;
  bool loading = false;
  bool loadingMore = false;
  bool reloadRequested = false;
  bool hasMore = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    await widget.onRefreshProcessing();
    await _load();
  }

  Future<void> _load({bool more = false}) async {
    if (loading || loadingMore) {
      if (!more) reloadRequested = true;
      return;
    }
    if (more && !hasMore) return;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        error = null;
        cursor = null;
      }
    });
    try {
      final page = await widget.service.load(
        query: search.text,
        cursor: more ? cursor : null,
      );
      if (!mounted) return;
      final merged = more ? [...items, ...page.items] : page.items;
      final unique = <String, TimelineItem>{};
      for (final item in merged) {
        unique[item.eventKey] = item;
      }
      setState(() {
        items = unique.values.toList()..sort(_compareItems);
        cursor = page.nextCursor;
        hasMore = page.hasMore;
        error = null;
      });
    } on TimelineServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Timeline could not be loaded. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
        if (reloadRequested) {
          reloadRequested = false;
          unawaited(_load());
        }
      }
    }
  }

  void _searchChanged(String _) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  List<TimelineItem> get _currentItems {
    final byJob = <String, TimelineItem>{};
    final withoutJobs = <TimelineItem>[];
    for (final item in items) {
      if (item.jobId == null) {
        withoutJobs.add(item);
      } else {
        byJob[item.jobId!] = item;
      }
    }
    for (final job in widget.processingJobs) {
      final existing = byJob[job.id];
      final updated = _applyJob(existing, job);
      if (existing != null || updated.matchesSearch(search.text)) {
        byJob[job.id] = updated;
      }
    }
    final combined = [...withoutJobs, ...byJob.values]..sort(_compareItems);
    return combined.where((item) {
      return switch (filter) {
        TimelineFilter.all => true,
        TimelineFilter.documents => item.kind == TimelineItemKind.document,
        TimelineFilter.links => item.kind == TimelineItemKind.link,
        TimelineFilter.messages => item.kind == TimelineItemKind.message,
        TimelineFilter.reminders => item.kind == TimelineItemKind.reminder,
      };
    }).toList();
  }

  TimelineItem _applyJob(TimelineItem? item, AnalysisJob job) {
    final base =
        item ??
        TimelineItem(
          id: job.id,
          eventKey: 'analysis:${job.id}',
          kind: TimelineItemKind.document,
          eventType: 'document_processing',
          title: job.displayTitle ?? 'Document',
          occurredAt: job.updatedAt ?? DateTime.now(),
          documentId: job.documentId,
          jobId: job.id,
        );
    final documentTitle =
        job.result?.title ??
        job.displayTitle ??
        _plainDocumentTitle(base.title);
    return base.copyWith(
      title: switch (job.status) {
        'queued' || 'retry_wait' => '$documentTitle queued for reading',
        'processing' => 'Reading $documentTitle…',
        'succeeded' => 'Finished reading $documentTitle',
        'failed' || 'permanent_failed' => 'I couldn’t read this document.',
        _ => base.title,
      },
      context: job.result?.category ?? base.context,
      occurredAt: job.updatedAt,
      status: job.status,
      category: job.result?.category,
      tags: job.result?.tags,
      retryAllowed: job.retryAllowed,
    );
  }

  String _plainDocumentTitle(String value) => value
      .replaceFirst(RegExp(r'^Finished reading\s+'), '')
      .replaceFirst(RegExp(r'^Reading\s+'), '')
      .replaceFirst(RegExp(r'\s+queued for reading$'), '')
      .replaceFirst(RegExp(r'…$'), '');

  int _compareItems(TimelineItem a, TimelineItem b) {
    final byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : b.eventKey.compareTo(a.eventKey);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final current = _currentItems;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        key: const ValueKey('timeline-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(wide ? 32 : 16, 24, wide ? 32 : 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Timeline',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                color: Color(0xff17233a),
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Everything you’ve saved and received, newest first.',
                              style: TextStyle(color: Color(0xff64748b)),
                            ),
                          ],
                        ),
                      ),
                      if (wide)
                        IconButton(
                          onPressed: loading ? null : refresh,
                          tooltip: 'Refresh Timeline',
                          icon: const Icon(Icons.refresh),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const ValueKey('timeline-search'),
                    controller: search,
                    onChanged: _searchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search your Timeline',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear Timeline search',
                              onPressed: () {
                                search.clear();
                                setState(() {});
                                _load();
                              },
                              icon: const Icon(Icons.close),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: TimelineFilter.values.map((value) {
                        final selected = filter == value;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            selected: selected,
                            label: Text(_filterLabel(value)),
                            onSelected: (_) => setState(() => filter = value),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (loading && items.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (error != null && items.isEmpty)
                    _TimelineError(message: error!, onRetry: _load)
                  else if (current.isEmpty)
                    _TimelineEmpty(
                      text: search.text.trim().isNotEmpty
                          ? 'Nothing matched your search.'
                          : filter == TimelineFilter.documents
                          ? 'No documents in your Timeline.'
                          : filter == TimelineFilter.all
                          ? 'Nothing has been saved yet.'
                          : 'Nothing matched this filter.',
                    )
                  else
                    ..._grouped(current),
                  if (error != null && items.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _TimelineError(message: error!, onRetry: _load),
                  ],
                  if (hasMore) ...[
                    const SizedBox(height: 16),
                    Center(
                      child: OutlinedButton(
                        onPressed: loadingMore ? null : () => _load(more: true),
                        child: Text(loadingMore ? 'Loading…' : 'Load more'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _grouped(List<TimelineItem> values) {
    final result = <Widget>[];
    final active = values.where((item) => item.isActive).toList()
      ..sort(_compareItems);
    final history = values.where((item) => !item.isActive).toList()
      ..sort(_compareItems);
    if (active.isNotEmpty) {
      result.add(
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            'Active processing',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
      result.addAll(
        active.map(
          (item) => _TimelineRow(item: item, onTap: () => _openItem(item)),
        ),
      );
    }
    String? previous;
    for (final item in history) {
      final group = _groupLabel(item.occurredAt);
      if (group != previous) {
        result.add(
          Padding(
            padding: EdgeInsets.only(
              top: previous == null && active.isEmpty ? 0 : 24,
              bottom: 6,
            ),
            child: Text(
              group,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        );
        previous = group;
      }
      result.add(_TimelineRow(item: item, onTap: () => _openItem(item)));
    }
    return result;
  }

  Future<void> _openItem(TimelineItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final detail = _TimelineDetail(
            item: item,
            onOpenDocument:
                item.documentId == null || widget.onOpenDocument == null
                ? null
                : () => widget.onOpenDocument!(item.documentId!),
            onRetry: item.jobId == null
                ? null
                : () => widget.onRetryJob(item.jobId!),
            onSaveWithoutReading: item.jobId == null
                ? null
                : () => widget.onSaveWithoutReading(item.jobId!),
            onChooseCategory: item.jobId == null
                ? null
                : () => widget.onChooseCategory(item.jobId!),
            onDismiss: item.jobId == null
                ? null
                : () => widget.onDismissJob(item.jobId!),
          );
          if (constraints.maxWidth < 360 || constraints.maxHeight < 520) {
            return Dialog.fullscreen(child: detail);
          }
          return Dialog(
            child: ConstrainedBox(
              key: const ValueKey('timeline-detail-dialog'),
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: constraints.maxHeight * .86,
              ),
              child: detail,
            ),
          );
        },
      ),
    );
  }

  String _filterLabel(TimelineFilter value) => switch (value) {
    TimelineFilter.all => 'All',
    TimelineFilter.documents => 'Documents',
    TimelineFilter.links => 'Links',
    TimelineFilter.messages => 'Messages',
    TimelineFilter.reminders => 'Reminders',
  };

  String _groupLabel(DateTime value) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(value.year, value.month, value.day);
    if (date == today) return 'Today';
    if (date == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.item, required this.onTap});
  final TimelineItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('timeline-item-${item.eventKey}'),
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xffe8edf3))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Icon(
              _icon(item.kind),
              size: 21,
              color: const Color(0xff45617f),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if ((item.context ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.context!,
                    style: const TextStyle(color: Color(0xff64748b)),
                  ),
                ],
                if (item.status != null &&
                    (item.isActive || item.isFailed)) ...[
                  const SizedBox(height: 5),
                  Text(
                    _status(item.status!),
                    style: TextStyle(
                      color: item.isFailed
                          ? const Color(0xffa72d2d)
                          : const Color(0xff5755c9),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (item.status == 'succeeded' && item.tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Tags: ${item.tags.join(', ')}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff64748b),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            TimeOfDay.fromDateTime(item.occurredAt).format(context),
            style: const TextStyle(fontSize: 12, color: Color(0xff64748b)),
          ),
          const SizedBox(width: 2),
          if (item.kind == TimelineItemKind.document &&
              item.status == 'succeeded')
            TextButton(onPressed: onTap, child: const Text('Open'))
          else
            const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    ),
  );

  static IconData _icon(TimelineItemKind kind) => switch (kind) {
    TimelineItemKind.document => Icons.description_outlined,
    TimelineItemKind.link => Icons.link,
    TimelineItemKind.message => Icons.mail_outline,
    TimelineItemKind.reminder => Icons.notifications_outlined,
  };

  static String _status(String value) => switch (value) {
    'queued' || 'retry_wait' => 'Queued',
    'processing' => 'Reading',
    'succeeded' => 'Finished',
    'failed' || 'permanent_failed' => 'Couldn’t read document',
    _ => value,
  };
}

class _TimelineDetail extends StatelessWidget {
  const _TimelineDetail({
    required this.item,
    this.onRetry,
    this.onSaveWithoutReading,
    this.onChooseCategory,
    this.onDismiss,
    this.onOpenDocument,
  });
  final TimelineItem item;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onSaveWithoutReading;
  final Future<void> Function()? onChooseCategory;
  final Future<void> Function()? onDismiss;
  final Future<void> Function()? onOpenDocument;

  @override
  Widget build(BuildContext context) => Semantics(
    scopesRoute: true,
    namesRoute: true,
    explicitChildNodes: true,
    label: 'Timeline item details',
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  autofocus: true,
                  tooltip: 'Close details',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('timeline-detail-scroll'),
                child: _detailContent(context),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _detailContent(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if ((item.context ?? '').isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(item.context!),
      ],
      if ((item.category ?? '').isNotEmpty) ...[
        const SizedBox(height: 18),
        const Text('Category', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Chip(label: Text(item.category!)),
      ],
      if (item.kind == TimelineItemKind.document) ...[
        const SizedBox(height: 10),
        const Text('Tags', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (item.tags.isEmpty)
          const Text('No tags added')
        else
          Wrap(
            spacing: 6,
            children: item.tags.map((tag) => Chip(label: Text(tag))).toList(),
          ),
      ],
      if (onOpenDocument != null) ...[
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: () => onOpenDocument!(),
          icon: const Icon(Icons.visibility_outlined),
          label: const Text('Open document'),
        ),
      ],
      if ((item.url ?? '').isNotEmpty) ...[
        const SizedBox(height: 14),
        SelectableText(item.url!),
      ],
      if (item.isFailed) ...[
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (item.retryAllowed && onRetry != null)
              FilledButton(
                onPressed: () => _run(context, onRetry!),
                child: const Text('Retry reading'),
              ),
            if (onSaveWithoutReading != null)
              OutlinedButton(
                onPressed: () => _run(context, onSaveWithoutReading!),
                child: const Text('Save without reading'),
              ),
            if (onChooseCategory != null)
              TextButton(
                onPressed: () => _run(context, onChooseCategory!),
                child: const Text('Choose category'),
              ),
            if (onDismiss != null)
              TextButton(
                onPressed: () => _run(context, onDismiss!),
                child: const Text('Dismiss'),
              ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ),
    ],
  );

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    Navigator.pop(context);
    await action();
  }
}

class _TimelineError extends StatelessWidget {
  const _TimelineError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xfffff7f7),
      border: Border.all(color: const Color(0xfff3c4c4)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Color(0xffa72d2d)),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

class _TimelineEmpty extends StatelessWidget {
  const _TimelineEmpty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Center(child: Text(text, textAlign: TextAlign.center)),
  );
}
