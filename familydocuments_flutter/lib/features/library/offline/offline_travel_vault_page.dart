import 'package:flutter/material.dart';

import '../data/library_service.dart';
import '../document_viewer.dart';
import 'offline_travel_models.dart';
import 'offline_vault_authenticator_models.dart';

class OfflineTravelVaultPage extends StatefulWidget {
  const OfflineTravelVaultPage({
    super.key,
    required this.store,
    required this.authenticator,
    required this.onClose,
  });

  final OfflineTravelStore store;
  final OfflineVaultAuthenticator authenticator;
  final VoidCallback onClose;

  @override
  State<OfflineTravelVaultPage> createState() => _OfflineTravelVaultPageState();
}

class _OfflineTravelVaultPageState extends State<OfflineTravelVaultPage>
    with WidgetsBindingObserver {
  bool authenticating = true;
  bool unlocked = false;
  String? error;
  List<OfflineTravelDocument> documents = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _unlock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      if (mounted) setState(() => unlocked = false);
    }
  }

  Future<void> _unlock() async {
    setState(() {
      authenticating = true;
      error = null;
    });
    final accepted = await widget.authenticator.authenticate();
    if (!mounted) return;
    if (!accepted) {
      setState(() {
        authenticating = false;
        unlocked = false;
        error = 'Your phone did not unlock the offline travel pack.';
      });
      return;
    }
    try {
      final values = await widget.store.listAll();
      if (!mounted) return;
      setState(() {
        documents = values;
        authenticating = false;
        unlocked = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          authenticating = false;
          unlocked = false;
          error = 'The encrypted travel pack could not be opened.';
        });
      }
    }
  }

  Future<void> _open(OfflineTravelDocument document) => showDocumentViewer(
    context,
    documentId: document.documentId,
    loadSource: (_) async {
      final file = await widget.store.read(document.documentId);
      if (file == null) {
        throw const LibraryServiceException(
          'This offline copy has expired or was removed.',
        );
      }
      return LibrarySource(
        fileName: file.document.fileName,
        mimeType: file.document.mimeType,
        bytes: file.bytes,
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Offline travel pack'),
      leading: IconButton(
        tooltip: 'Return to sign in',
        onPressed: widget.onClose,
        icon: const Icon(Icons.close),
      ),
    ),
    body: authenticating
        ? const Center(child: CircularProgressIndicator())
        : !unlocked
        ? Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      error ?? 'Unlock this travel pack with your phone.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _unlock,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Unlock travel pack'),
                    ),
                  ],
                ),
              ),
            ),
          )
        : documents.isEmpty
        ? const Center(child: Text('No unexpired offline documents remain.'))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: documents.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final document = documents[index];
              return ListTile(
                leading: const Icon(Icons.offline_pin),
                title: Text(document.title),
                subtitle: Text(
                  '${document.tripTitle} · available until ${_date(document.expiresAt)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(document),
              );
            },
          ),
  );

  String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}
