import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'data/library_service.dart';
import 'safe_open.dart';

typedef DocumentSourceLoader = Future<LibrarySource> Function(String id);
typedef DocumentFileAction = Future<bool> Function(
  String name,
  String mimeType,
  Uint8List bytes,
);

Future<void> showDocumentViewer(
  BuildContext context, {
  required String documentId,
  required DocumentSourceLoader loadSource,
  DocumentFileAction? download,
  DocumentFileAction? openExternally,
}) => showDialog<void>(
  context: context,
  builder: (_) => _DocumentViewer(
    documentId: documentId,
    loadSource: loadSource,
    download: download ?? downloadDocument,
    openExternally: openExternally ?? openDocumentExternally,
  ),
);

class _DocumentViewer extends StatefulWidget {
  const _DocumentViewer({
    required this.documentId,
    required this.loadSource,
    required this.download,
    required this.openExternally,
  });
  final String documentId;
  final DocumentSourceLoader loadSource;
  final DocumentFileAction download, openExternally;

  @override
  State<_DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<_DocumentViewer> {
  late Future<LibrarySource> source;
  final pdf = PdfViewerController();
  int page = 1;
  bool working = false;

  @override
  void initState() {
    super.initState();
    source = widget.loadSource(widget.documentId);
  }

  void retry() {
    final next = widget.loadSource(widget.documentId);
    setState(() {
      source = next;
    });
  }

  Future<void> fileAction(
    LibrarySource value,
    DocumentFileAction action,
  ) async {
    if (working) return;
    setState(() => working = true);
    try {
      final ok = await action(value.fileName, value.mimeType, value.bytes);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This action is not available on this device.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The file could not be opened. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      final phone = viewport.maxWidth < 600 || viewport.maxHeight < 540;
      final content = Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Document viewer',
        child: SafeArea(
          child: FutureBuilder<LibrarySource>(
            future: source,
            builder: (context, snapshot) {
              final value = snapshot.data;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            value?.fileName ?? 'Document',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          autofocus: true,
                          tooltip: 'Close document',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: _body(snapshot)),
                  if (value != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: working
                                ? null
                                : () => fileAction(value, widget.download),
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('Download'),
                          ),
                          if ({
                            'application/pdf',
                            'image/jpeg',
                            'image/png',
                          }.contains(value.mimeType.toLowerCase()))
                            OutlinedButton.icon(
                              onPressed: working
                                  ? null
                                  : () => fileAction(
                                      value,
                                      widget.openExternally,
                                    ),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Open externally'),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
      if (phone) return Dialog.fullscreen(child: content);
      return Dialog(
        child: SizedBox(
          width: viewport.maxWidth.clamp(0, 960).toDouble(),
          height: viewport.maxHeight * .88,
          child: content,
        ),
      );
    },
  );

  Widget _body(AsyncSnapshot<LibrarySource> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading document'),
      );
    }
    if (snapshot.hasError) {
      final error = snapshot.error;
      final message = error is LibraryServiceException
          ? error.message
          : 'The file could not be loaded. Try again.';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(onPressed: retry, child: const Text('Retry')),
          ],
        ),
      );
    }
    final value = snapshot.data!;
    final mime = value.mimeType.toLowerCase();
    if (mime == 'application/pdf' ||
        value.fileName.toLowerCase().endsWith('.pdf')) {
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Previous page',
                onPressed: page > 1 && pdf.isReady
                    ? () => pdf.goToPage(pageNumber: page - 1)
                    : null,
                icon: const Icon(Icons.navigate_before),
              ),
              Text('Page $page${pdf.isReady ? ' of ${pdf.pageCount}' : ''}'),
              IconButton(
                tooltip: 'Next page',
                onPressed: pdf.isReady && page < pdf.pageCount
                    ? () => pdf.goToPage(pageNumber: page + 1)
                    : null,
                icon: const Icon(Icons.navigate_next),
              ),
              IconButton(
                tooltip: 'Zoom out',
                onPressed: pdf.isReady ? pdf.zoomDown : null,
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                tooltip: 'Zoom in',
                onPressed: pdf.isReady ? pdf.zoomUp : null,
                icon: const Icon(Icons.zoom_in),
              ),
            ],
          ),
          Expanded(
            child: PdfViewer.data(
              value.bytes,
              sourceName: widget.documentId,
              controller: pdf,
              params: PdfViewerParams(
                onPageChanged: (number) {
                  if (mounted && number != null) setState(() => page = number);
                },
              ),
            ),
          ),
        ],
      );
    }
    if (mime == 'image/jpeg' || mime == 'image/png') {
      return InteractiveViewer(
        minScale: .5,
        maxScale: 5,
        child: Center(child: Image.memory(value.bytes, fit: BoxFit.contain)),
      );
    }
    return const Center(
      child: Text(
        'Preview is not available for this file type. You can download the original file.',
      ),
    );
  }
}
