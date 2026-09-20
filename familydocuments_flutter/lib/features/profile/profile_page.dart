import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../library/safe_open.dart';
import 'profile_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.auth,
    this.service,
    this.onAccountDeleted,
  });
  final AuthService auth;
  final ProfileService? service;
  final Future<void> Function()? onAccountDeleted;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileService service =
      widget.service ?? ProfileService(widget.auth);
  final name = TextEditingController();
  MemberProfile? profile;
  Uint8List? selectedPhoto;
  String? selectedMime, error;
  bool loading = true, saving = false, removePhoto = false;
  bool requestingDeletion = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await service.load();
      if (!mounted) return;
      name.text = result.displayName;
      setState(() {
        profile = result;
        error = null;
        loading = false;
      });
    } on ProfileException catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.message;
          loading = false;
        });
      }
    }
  }

  Future<void> _pickPhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    if (!mounted || result == null) return;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty || bytes.length > 1048576) {
      setState(() => error = 'Choose a JPG, PNG or WebP photo under 1 MB.');
      return;
    }
    final extension = file.extension?.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
    if (mime == null) {
      setState(() => error = 'Choose a JPG, PNG or WebP photo.');
      return;
    }
    setState(() {
      selectedPhoto = bytes;
      selectedMime = mime;
      removePhoto = false;
      error = null;
    });
  }

  Future<void> _save() async {
    if (saving) return;
    final cleanName = name.text.trim();
    if (cleanName.isEmpty || cleanName.length > 80) {
      setState(() => error = 'Enter a name between 1 and 80 characters.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await service.save(
        displayName: cleanName,
        photoMime: selectedMime,
        photoBase64: selectedPhoto == null
            ? null
            : base64Encode(selectedPhoto!),
        removePhoto: removePhoto,
      );
      if (!mounted) return;
      setState(() {
        profile = result;
        selectedPhoto = null;
        selectedMime = null;
        removePhoto = false;
        saving = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } on ProfileException catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.message;
          saving = false;
        });
      }
    }
  }

  Future<void> _requestDeletion() async {
    final confirmation = TextEditingController();
    var confirmationValid = false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This permanently deletes your FamilyDocuments login, profile and private account data. FamilyDocuments will not delete any files or folders from Google Drive.',
              ),
              const SizedBox(height: 16),
              const Text('Type DELETE to confirm.'),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('account-deletion-confirmation'),
                controller: confirmation,
                autofocus: true,
                onChanged: (value) => setDialogState(
                  () => confirmationValid = value.trim() == 'DELETE',
                ),
                decoration: const InputDecoration(
                  labelText: 'Confirmation',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: confirmationValid
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Delete account'),
            ),
          ],
        ),
      ),
    );
    confirmation.dispose();
    if (approved != true || !mounted) return;
    setState(() {
      requestingDeletion = true;
      error = null;
    });
    try {
      final deleted = await service.deleteAccount();
      if (!deleted) {
        throw ProfileException('The server did not confirm account deletion.');
      }
      if (!mounted) return;
      setState(() => requestingDeletion = false);
      await widget.auth.clear();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Account deleted'),
          content: const Text(
            'Your FamilyDocuments account has been deleted. Your Google Drive files and folders remain untouched.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      await widget.onAccountDeleted?.call();
    } on ProfileException catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.message;
          requestingDeletion = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final savedPhoto = profile?.photoBase64;
    final bytes =
        selectedPhoto ??
        (!removePhoto && savedPhoto != null ? base64Decode(savedPhoto) : null);
    final initials = name.text.trim().isEmpty
        ? widget.auth.session?.email.substring(0, 1).toUpperCase() ?? 'F'
        : name.text.trim().substring(0, 1).toUpperCase();
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: loading
              ? const CircularProgressIndicator()
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (error != null) ...[
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (profile == null)
                      FilledButton(
                        onPressed: _load,
                        child: const Text('Try again'),
                      )
                    else ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    radius: 38,
                                    backgroundColor: const Color(0xffeeedff),
                                    foregroundColor: const Color(0xff34327f),
                                    backgroundImage: bytes == null
                                        ? null
                                        : MemoryImage(bytes),
                                    child: bytes == null
                                        ? Text(
                                            initials,
                                            style: const TextStyle(
                                              fontSize: 26,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(width: 18),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Your profile',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                        const Text(
                                          'Your display name appears to family members. Your photo stays private to your account for now.',
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: saving ? null : _pickPhoto,
                                    icon: const Icon(
                                      Icons.photo_camera_outlined,
                                    ),
                                    label: const Text('Add or change photo'),
                                  ),
                                  if (bytes != null)
                                    TextButton(
                                      onPressed: saving
                                          ? null
                                          : () => setState(() {
                                              selectedPhoto = null;
                                              selectedMime = null;
                                              removePhoto = true;
                                            }),
                                      child: const Text('Remove photo'),
                                    ),
                                ],
                              ),
                              const Text(
                                'JPG, PNG or WebP, up to 1 MB. Stored privately with your account.',
                              ),
                              const SizedBox(height: 20),
                              TextField(
                                controller: name,
                                maxLength: 80,
                                decoration: const InputDecoration(
                                  labelText: 'Display name',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Email: ${widget.auth.session?.email ?? ''}',
                              ),
                              const SizedBox(height: 8),
                              FilledButton(
                                onPressed: saving ? null : _save,
                                child: Text(
                                  saving ? 'Saving…' : 'Save profile',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your families',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              if (profile!.families.isEmpty)
                                const Text('No active family membership yet.'),
                              for (final family in profile!.families)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.group_outlined),
                                  title: Text(family.name),
                                  subtitle: Text(
                                    '${family.role.replaceAll('_', ' ')}${family.joinedAt == null ? '' : ' · Joined ${family.joinedAt!.year}-${family.joinedAt!.month.toString().padLeft(2, '0')}-${family.joinedAt!.day.toString().padLeft(2, '0')}'}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: const Text('Terms of use'),
                            trailing: const Icon(Icons.open_in_new),
                            onTap: () => openExternalLink(
                              'https://familydocuments.app/terms',
                            ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.privacy_tip_outlined),
                            title: const Text('Privacy policy'),
                            trailing: const Icon(Icons.open_in_new),
                            onTap: () => openExternalLink(
                              'https://familydocuments.app/privacy',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Account and data',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Permanently delete your login, profile and private account data. Your Google Drive files and folders will remain untouched.',
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              key: const ValueKey('request-account-deletion'),
                              onPressed: requestingDeletion
                                  ? null
                                  : _requestDeletion,
                              icon: const Icon(Icons.delete_forever_outlined),
                              label: Text(
                                requestingDeletion
                                    ? 'Deleting…'
                                    : 'Delete account',
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
