import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/auth/auth_service.dart';
import 'drive_oauth.dart';
import 'drive_service.dart';

const driveClientId = String.fromEnvironment('GOOGLE_DRIVE_CLIENT_ID');

class DrivePage extends StatefulWidget {
  const DrivePage({
    super.key,
    required this.auth,
    this.repository,
    this.prepareAuthorization = prepareDriveAuthorization,
    this.authorize = requestDriveAuthorization,
    this.clientId = driveClientId,
  });
  final AuthService auth;
  final DriveRepository? repository;
  final Future<void> Function() prepareAuthorization;
  final Future<String> Function(String) authorize;
  final String clientId;
  @override
  State<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<DrivePage> {
  late final DriveRepository service =
      widget.repository ?? DriveService(widget.auth);
  DriveConnection? connection;
  List<DriveFolder> folders = [];
  bool busy = false, identityVerified = false, googleReady = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } on AuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on DriveException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The connection could not be completed. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refreshStatus() async {
    final latest = await service.status();
    if (!mounted) return;
    if (connection?.familyId != latest.familyId) {
      identityVerified = false;
      folders = [];
    }
    setState(() => connection = latest);
  }

  Future<void> load() => run(refreshStatus);

  Future<void> verifyIdentity() => run(() async {
    final success = await showDialog<bool>(
      context: context,
      builder: (_) => _IdentityDialog(auth: widget.auth),
    );
    if (success != true || !mounted) return;
    await refreshStatus();
    identityVerified = true;
    if (widget.clientId.isNotEmpty) {
      await widget.prepareAuthorization();
      googleReady = true;
    }
    if (connection?.state == DriveConnectionState.chooseFolder ||
        connection?.canSave == true) {
      folders = await service.folders();
    }
  });

  Future<void> connect() {
    // Request the popup before any async network operation loses user activation.
    final code = widget.authorize(widget.clientId);
    return run(() async {
      await service.connect(await code);
      await refreshStatus();
      folders = await service.folders();
    });
  }

  Future<void> createFolder() async {
    final controller = TextEditingController(text: 'FamilyDocuments');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create a folder in Google Drive'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await run(() async {
      final folder = await service.createFolder(name);
      // Creation and selection are separate: a failed selection never creates
      // another folder automatically. Refresh will list the existing folder.
      folders = [...folders, folder];
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = connection;
    final status = switch (current?.state) {
      DriveConnectionState.connected => 'Connected',
      DriveConnectionState.chooseFolder => 'Choose a folder',
      DriveConnectionState.reconnectRequired => 'Reconnect Google Drive',
      DriveConnectionState.disconnected => 'Disconnected',
      DriveConnectionState.notConnected => 'Not connected',
      null => 'Checking Google Drive…',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Your Family’s documents belong in your Google Drive.',
              ),
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (current?.folderName != null)
                Text('Folder: ${current!.folderName}'),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(),
                ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(error!),
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('Refresh connection'),
                ),
              ],
              if (current != null && !current.canManage)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Ask a Family administrator to connect or change Google Drive.',
                  ),
                ),
              if (current?.canManage == true) ...[
                const SizedBox(height: 16),
                if (!identityVerified)
                  FilledButton(
                    onPressed: busy ? null : verifyIdentity,
                    child: const Text('Verify identity to manage Drive'),
                  ),
                if (identityVerified &&
                    current?.state != DriveConnectionState.chooseFolder &&
                    current?.canSave != true) ...[
                  if (widget.clientId.isEmpty)
                    const Text(
                      'Google Drive authorization is not configured for this environment. Contact the app administrator.',
                    ),
                  if (!kIsWeb)
                    const Text(
                      'Use the web app to connect your Google account.',
                    ),
                  if (googleReady)
                    FilledButton(
                      onPressed: busy ? null : connect,
                      child: const Text('Connect Google Drive'),
                    ),
                ],
                if (identityVerified &&
                    (current?.state == DriveConnectionState.chooseFolder ||
                        current?.canSave == true)) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Choose an app-accessible folder, or create a new one. Existing documents will not be moved.',
                  ),
                  for (final folder in folders)
                    ListTile(
                      title: Text(folder.name),
                      leading: const Icon(Icons.folder_outlined),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () => run(() async {
                              await service.selectFolder(folder.id);
                              await refreshStatus();
                            }),
                    ),
                  if (folders.isEmpty)
                    const Text('No app-accessible folders yet.'),
                  TextButton.icon(
                    onPressed: busy ? null : createFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Create folder'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Disconnect Google Drive?'),
                                content: const Text(
                                  'Your files will remain in Google Drive. Saving and opening Drive documents will be unavailable until you reconnect.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Disconnect'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && mounted) {
                              await run(() async {
                                await service.disconnect();
                                folders = [];
                                await refreshStatus();
                              });
                            }
                          },
                    child: const Text('Disconnect'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IdentityDialog extends StatefulWidget {
  const _IdentityDialog({required this.auth});
  final AuthService auth;
  @override
  State<_IdentityDialog> createState() => _IdentityDialogState();
}

class _IdentityDialogState extends State<_IdentityDialog> {
  final code = TextEditingController();
  String? factor, setupKey, setupUri, error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> prepare() async {
    try {
      final factors = await widget.auth.totpFactors();
      if (factors.isNotEmpty) {
        factor = factors.first['id'] as String;
      } else {
        final enrolled = await widget.auth.enrollTotp();
        factor = enrolled['id'] as String;
        final totp = enrolled['totp'] as Map;
        setupKey = totp['secret'] as String;
        final uri = Uri.tryParse(totp['uri'] as String? ?? '');
        if (uri?.scheme == 'otpauth' && uri?.host == 'totp') {
          setupUri = uri.toString();
        }
      }
    } on AuthException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Identity verification is unavailable. Try again.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Verify your identity'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) const LinearProgressIndicator(),
            if (setupKey != null) ...[
              if (setupUri != null)
                const Text(
                  'Scan this code with your authenticator app, then enter its six-digit code.',
                )
              else
                const Text(
                  'Add the setup key to your authenticator app, then enter its six-digit code.',
                ),
              if (setupUri != null)
                Semantics(
                  label: 'Authenticator setup QR code',
                  image: true,
                  excludeSemantics: true,
                  child: QrImageView(
                    data: setupUri!,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
                ),
              ExpansionTile(
                title: const Text('Use setup key instead'),
                initiallyExpanded: setupUri == null,
                children: [
                  const Text('Keep this key private.'),
                  SelectableText(setupKey!),
                ],
              ),
            ],
            TextField(
              controller: code,
              autofocus: setupKey == null,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Authenticator code',
              ),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy || factor == null
            ? null
            : () async {
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  await widget.auth.verifyTotp(factor!, code.text.trim());
                  if (context.mounted) Navigator.pop(context, true);
                } on AuthException catch (e) {
                  if (mounted) setState(() => error = e.message);
                } finally {
                  if (mounted) setState(() => busy = false);
                }
              },
        child: const Text('Verify'),
      ),
    ],
  );
}
