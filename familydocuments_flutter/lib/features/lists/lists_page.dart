import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/auth/auth_service.dart';

// A dialog's result completes before its closing animation. Keep form
// controllers alive until the route has actually removed its widgets.
Future<void> showListDialog({required BuildContext context, required WidgetBuilder builder}) async {
  final route = DialogRoute<void>(context: context, builder: builder);
  await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
}

String listRequestId() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

class ListsService {
  ListsService(this.auth, {http.Client? client})
    : client = client ?? http.Client();
  final AuthService auth;
  final http.Client client;
  Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() async => client.post(
      Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$operation'),
      headers: {
        'authorization': 'Bearer ${await auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    var response = await send();
    if (response.statusCode == 401) {
      await auth.refresh();
      response = await send();
    }
    if (response.statusCode != 200) {
      throw Exception(
        response.body.contains('40001')
            ? 'This item changed. Refresh before editing again.'
            : 'Could not save or load the list. Your input has been kept. Try again.',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void dispose() => client.close();
}

class ListsPage extends StatefulWidget {
  const ListsPage({
    super.key,
    required this.auth,
    this.service,
    this.initialTitle,
  });
  final AuthService auth;
  final ListsService? service;
  final String? initialTitle;
  @override
  State<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends State<ListsPage> {
  late final ListsService service = widget.service ?? ListsService(widget.auth);
  List<dynamic> lists = [], items = [], members = [], history = [];
  Map<String, dynamic>? selected;
  bool loading = true, busy = false, showCompleted = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    if (widget.service == null) service.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = selected == null
          ? await service.call('household_lists_dashboard', {})
          : await service.call('household_list_workspace', {
              'target_list': selected!['id'],
            });
      if (!mounted) return;
      setState(() {
        lists = data['lists'] ?? lists;
        items = data['items'] ?? [];
        members = data['members'] ?? [];
        history = data['history'] ?? [];
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> createList() async {
    final title = TextEditingController();
    final id = listRequestId();
    String kind = 'groceries';
    await showListDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          return AlertDialog(
            title: const Text('New shared list'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'List name'),
                ),
                DropdownButton<String>(
                  value: kind,
                  isExpanded: true,
                  items: ['groceries', 'errands', 'chores']
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: busy ? null : (v) => update(() => kind = v!),
                ),
                if (error != null) Text(error!),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (title.text.trim().isEmpty) return;
                        update(() => busy = true);
                        try {
                          await service.call('create_household_list', {
                            'request_id': id,
                            'list_title': title.text.trim(),
                            'list_kind': kind,
                          });
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          update(() => error = e.toString());
                        } finally {
                          if (mounted) {
                            busy = false;
                            if (context.mounted) update(() {});
                          }
                        }
                      },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
    title.dispose();
    await load();
  }

  Future<void> editItem([Map<String, dynamic>? item, String? seedTitle]) async {
    final title = TextEditingController(
      text: item?['title'] ?? seedTitle ?? '',
    );
    final quantity = TextEditingController(text: item?['quantity'] ?? '');
    final notes = TextEditingController(text: item?['notes'] ?? '');
    final section = TextEditingController(text: item?['section'] ?? '');
    final due = TextEditingController(text: item?['due_on'] ?? '');
    final id = item?['id'] ?? listRequestId();
    String? assignee = item?['assigned_to'];
    if (!members.any((m) => m['id'] == assignee)) assignee = null;
    String recurrence = item?['recurrence'] ?? 'none';
    String? formError;
    bool saving = false;
    await showListDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(item == null ? 'Add item' : 'Edit item'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    maxLength: 240,
                    decoration: const InputDecoration(
                      labelText: 'Item or task',
                    ),
                  ),
                  TextField(
                    controller: quantity,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: 'Quantity (optional)',
                    ),
                  ),
                  TextField(
                    controller: section,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Store or category (optional)',
                    ),
                  ),
                  TextField(
                    controller: notes,
                    maxLength: 2000,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: assignee,
                    hint: const Text('Unassigned'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      ...members.map(
                        (m) => DropdownMenuItem<String>(
                          value: m['id'],
                          child: Text(m['name'] ?? 'Member'),
                        ),
                      ),
                    ],
                    onChanged: saving
                        ? null
                        : (v) => update(() => assignee = v),
                  ),
                  TextField(
                    controller: due,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Due date (optional)',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => update(() => due.clear()),
                      ),
                    ),
                    onTap: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate:
                            DateTime.tryParse(due.text) ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (date != null) {
                        update(
                          () => due.text = date.toIso8601String().substring(
                            0,
                            10,
                          ),
                        );
                      }
                    },
                  ),
                  if (selected!['kind'] == 'chores')
                    DropdownButton<String>(
                      value: recurrence,
                      isExpanded: true,
                      items: ['none', 'daily', 'weekly', 'monthly']
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text('Repeat: $v'),
                            ),
                          )
                          .toList(),
                      onChanged: saving
                          ? null
                          : (v) => update(() => recurrence = v!),
                    ),
                  const Text(
                    'Due dates do not send alerts. Repeating chores advance from their due date when completed. Monthly dates clamp to the last day of shorter months.',
                  ),
                  if (formError != null) Text(formError!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (title.text.trim().isEmpty ||
                          (recurrence != 'none' && due.text.isEmpty)) {
                        update(
                          () => formError = 'Enter a title and a due date for repeating chores.',
                        );
                        return;
                      }
                      update(() => saving = true);
                      try {
                        await service.call('save_household_list_item', {
                          'target_list': selected!['id'],
                          'item_id': id,
                          'expected_version': item?['version'] ?? 0,
                          'details': {
                            'title': title.text.trim(),
                            'quantity': quantity.text,
                            'notes': notes.text,
                            'section': section.text,
                            'assigned_to': assignee,
                            'due_on': due.text.isEmpty ? null : due.text,
                            'recurrence': recurrence,
                          },
                        });
                        if (context.mounted) Navigator.pop(context);
                      } catch (e) {
                        if (context.mounted) {
                          update(() => formError = e.toString());
                        }
                      } finally {
                        if (context.mounted) update(() => saving = false);
                      }
                    },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    for (final c in [title, quantity, notes, section, due]) {
      c.dispose();
    }
    await load();
  }

  Future<void> complete(Map<String, dynamic> item) async {
    setState(() => busy = true);
    try {
      await service.call('complete_household_list_item', {
        'item_id': item['id'],
        'expected_version': item['version'],
        'completed': item['completed_at'] == null,
      });
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (selected != null)
              IconButton(
                tooltip: 'All lists',
                onPressed: busy
                    ? null
                    : () {
                        setState(() => selected = null);
                        load();
                      },
                icon: const Icon(Icons.arrow_back),
              ),
            Text(
              selected?['title'] ?? 'Shared household lists',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            IconButton(
              tooltip: 'Refresh lists',
              onPressed: loading || busy ? null : load,
              icon: const Icon(Icons.refresh),
            ),
            FilledButton.icon(
              onPressed: loading || busy
                  ? null
                  : () => selected == null ? createList() : editItem(),
              icon: const Icon(Icons.add),
              label: Text(selected == null ? 'New list' : 'Add item'),
            ),
            if (selected != null)
              FilterChip(
                label: const Text('Show completed'),
                selected: showCompleted,
                onSelected: (v) => setState(() => showCompleted = v),
              ),
          ],
        ),
      ),
      const Text('Visible to all active members of this Family.'),
      if (error != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
      if (loading) const LinearProgressIndicator(),
      Expanded(
        child: selected == null
            ? ListView(
                children: [
                  if (!loading && lists.isEmpty)
                    const ListTile(
                      title: Text(
                        'Create your first grocery list, errand list or chore list.',
                      ),
                    ),
                  ...lists.map(
                    (l) => ListTile(
                      title: Text(l['title']),
                      subtitle: Text(l['kind']),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        setState(() => selected = Map<String, dynamic>.from(l));
                        await load();
                        if (mounted &&
                            error == null &&
                            widget.initialTitle != null) {
                          await editItem(null, widget.initialTitle);
                        }
                      },
                    ),
                  ),
                ],
              )
            : ListView(
                children: [
                  if (!loading && items.isEmpty)
                    const ListTile(
                      title: Text('Add the first item to this list.'),
                    ),
                  ...items
                      .where((i) => showCompleted || i['completed_at'] == null)
                      .map(
                        (i) => ListTile(
                          leading: Checkbox(
                            value: i['completed_at'] != null,
                            onChanged: busy
                                ? null
                                : (_) => complete(Map<String, dynamic>.from(i)),
                          ),
                          title: Text(i['title']),
                          subtitle: Text(
                            [
                              i['quantity'],
                              i['section'],
                              i['notes'],
                              i['due_on'],
                              if (i['recurrence'] != 'none') i['recurrence'],
                              ...members
                                  .where((m) => m['id'] == i['assigned_to'])
                                  .map((m) => m['name']),
                            ].where((v) => v != null && v != '').join(' · '),
                          ),
                          trailing: IconButton(
                            tooltip: 'Edit item',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: busy
                                ? null
                                : () => editItem(Map<String, dynamic>.from(i)),
                          ),
                        ),
                      ),
                  ExpansionTile(
                    title: const Text('Recent activity'),
                    children: history
                        .map(
                          (h) => ListTile(
                            title: Text(
                              '${h['snapshot']['title']} — ${h['action']}',
                            ),
                            subtitle: Text(h['created_at']),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
      ),
    ],
  );
}
