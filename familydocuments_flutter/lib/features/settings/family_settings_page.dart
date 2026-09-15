import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/auth/auth_service.dart';
import 'drive/drive_page.dart';

class FamilySettingsPage extends StatefulWidget {
  const FamilySettingsPage({super.key, required this.auth});
  final AuthService auth;
  @override
  State<FamilySettingsPage> createState() => _FamilySettingsPageState();
}

class _FamilySettingsPageState extends State<FamilySettingsPage> {
  late Future<Map> _snapshot = _load();
  bool _busy = false;
  Future<Map> _load() async {
    final response = await _rpc('household_snapshot', const {});
    if (response.statusCode != 200) throw StateError('snapshot unavailable');
    return jsonDecode(response.body) as Map;
  }

  Future<http.Response> _rpc(
    String operation,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() async => http.post(
      Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$operation'),
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

  Future<void> _change(String operation, Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final result = await _rpc(operation, body);
      if (result.statusCode != 200) {
        throw StateError(
          result.statusCode == 403
              ? 'Verify your identity with an authenticator, then try again.'
              : 'request failed',
        );
      }
      if (mounted) setState(() => _snapshot = _load());
    } on StateError catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmIdentity({
    required String title,
    required String message,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    final verified = await showDialog<bool>(
      context: context,
      builder: (_) => IdentityVerificationDialog(auth: widget.auth),
    );
    return verified == true;
  }

  Future<void> _manageMember(Map member, String action) async {
    final name = member['display_name']?.toString().isNotEmpty == true
        ? member['display_name'].toString()
        : member['email']?.toString() ?? 'this member';
    String? role;
    if (action == 'role') {
      role = await _chooseRole(member['role']?.toString() ?? 'viewer');
      if (role == null) return;
    }
    final labels = {
      'suspend': 'Suspend',
      'activate': 'Activate',
      'remove': 'Remove',
      'role': 'Change role',
    };
    final verb = labels[action]!;
    if (!await _confirmIdentity(
      title: '$verb $name?',
      message: action == 'remove'
          ? 'This removes their Family access and shared-document permissions. This cannot be undone from this screen.'
          : '$verb requires identity verification and is recorded in the Family security history.',
      action: verb,
    ))
      return;
    await _change('manage_member', {
      'member': member['id'],
      'action': action,
      'new_role': role,
    });
  }

  Future<String?> _chooseRole(String currentRole) => showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Choose Family role'),
      children: const ['viewer', 'contributor', 'adult_member', 'family_admin']
          .map(
            (role) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, role),
              child: Text(role),
            ),
          )
          .toList(),
    ),
  );

  Future<void> _transferOwnership(Map member) async {
    final name = member['display_name']?.toString().isNotEmpty == true
        ? member['display_name'].toString()
        : member['email']?.toString() ?? 'this member';
    if (!await _confirmIdentity(
      title: 'Transfer Family ownership?',
      message:
          '$name will become the owner. You will become an adult member. This security-sensitive change is recorded.',
      action: 'Transfer ownership',
    ))
      return;
    await _change('transfer_household_ownership', {'member': member['id']});
  }

  Future<void> _revokeInvitation(Map invitation) async {
    final email = invitation['email']?.toString() ?? 'this invitation';
    if (!await _confirmIdentity(
      title: 'Revoke invitation?',
      message: 'The pending invitation for $email will no longer be usable.',
      action: 'Revoke',
    ))
      return;
    await _change('revoke_invitation', {'invitation': invitation['id']});
  }

  Future<void> _invite() async {
    final email = TextEditingController();
    String role = 'viewer';
    final request = await showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Invite family member'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              DropdownButtonFormField(
                initialValue: role,
                items:
                    const [
                          'viewer',
                          'contributor',
                          'adult_member',
                          'family_admin',
                        ]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                onChanged: (value) => setDialogState(() => role = value!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (email.text.trim(), role)),
              child: const Text('Send invite'),
            ),
          ],
        ),
      ),
    );
    if (request != null && request.$1.isNotEmpty)
      await _change('invite_member', {
        'invitee_email': request.$1,
        'member_role': request.$2,
      });
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty)
      await _change('create_category', {'category_name': value});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Family settings')),
    body: FutureBuilder<Map>(
      future: _snapshot,
      builder: (context, result) {
        if (result.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        if (result.hasError)
          return Center(
            child: FilledButton(
              onPressed: () => setState(() => _snapshot = _load()),
              child: const Text('Try again'),
            ),
          );
        final data = result.data!;
        final current = data['current_user'] as Map?;
        final canManage = const [
          'owner',
          'family_admin',
        ].contains(current?['role']);
        final members = (data['members'] as List? ?? const []).whereType<Map>();
        final categories = (data['categories'] as List? ?? const [])
            .whereType<Map>();
        final invitations = (data['invitations'] as List? ?? const [])
            .whereType<Map>()
            .where((invitation) => invitation['status'] == 'pending');
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              data['household'] is Map
                  ? (data['household'] as Map)['name']?.toString() ?? 'Family'
                  : 'Family',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            Text('Your role: ${current?['role'] ?? 'member'}'),
            const SizedBox(height: 20),
            Row(
              children: [
                Text('Members', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (canManage)
                  TextButton(
                    onPressed: _busy ? null : _invite,
                    child: const Text('Invite'),
                  ),
              ],
            ),
            ...members.map(
              (member) => ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(
                  member['display_name']?.toString().isNotEmpty == true
                      ? member['display_name'].toString()
                      : member['email']?.toString() ?? 'Member',
                ),
                subtitle: Text(
                  '${member['email'] ?? ''} · ${member['role'] ?? ''} · ${member['status'] ?? ''}',
                ),
                trailing: canManage && member['id'] != current?['id']
                    ? PopupMenuButton<String>(
                        onSelected: (action) {
                          if (action == 'transfer') {
                            _transferOwnership(member);
                          } else {
                            _manageMember(member, action);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'role',
                            child: Text('Change role'),
                          ),
                          PopupMenuItem(
                            value: 'suspend',
                            child: Text('Suspend'),
                          ),
                          PopupMenuItem(
                            value: 'activate',
                            child: Text('Activate'),
                          ),
                          PopupMenuItem(value: 'remove', child: Text('Remove')),
                          if (current?['role'] == 'owner')
                            const PopupMenuItem(
                              value: 'transfer',
                              child: Text('Transfer ownership'),
                            ),
                        ],
                      )
                    : null,
              ),
            ),
            if (canManage && invitations.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Pending invitations',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              ...invitations.map(
                (invitation) => ListTile(
                  leading: const Icon(Icons.mark_email_unread_outlined),
                  title: Text(invitation['email']?.toString() ?? 'Invitation'),
                  subtitle: Text(
                    '${invitation['role'] ?? 'member'} · expires ${invitation['expires_at'] ?? ''}',
                  ),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _revokeInvitation(invitation),
                    child: const Text('Revoke'),
                  ),
                ),
              ),
            ],
            const Divider(),
            Row(
              children: [
                Text(
                  'Document categories',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (canManage)
                  TextButton(
                    onPressed: _busy ? null : _addCategory,
                    child: const Text('Add'),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Categories organise the shared Family Library. New categories are visible to every Family member and are backed by the Family Drive structure.',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: categories
                  .map(
                    (category) => Chip(
                      label: Text(category['name']?.toString() ?? 'Category'),
                    ),
                  )
                  .toList(),
            ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.shield_outlined),
              title: Text('Security'),
              subtitle: Text(
                'High-impact Family access changes require authenticator verification and are recorded in the security history.',
              ),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () => showDialog<bool>(
                        context: context,
                        builder: (_) =>
                            IdentityVerificationDialog(auth: widget.auth),
                      ),
                child: const Text('Verify now'),
              ),
            ),
          ],
        );
      },
    ),
  );
}
