import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:familydocuments_flutter/features/library/data/library_service.dart';
import 'package:familydocuments_flutter/features/library/document_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Z9sAAAAASUVORK5CYII=',
);

Uint8List _smallPdf() {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (final (number, body) in <(int, String)>[
    (1, '<< /Type /Catalog /Pages 2 0 R >>'),
    (2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    (
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>',
    ),
    (4, '<< /Length 0 >>\nstream\n\nendstream'),
  ]) {
    offsets.add(utf8.encode(out.toString()).length);
    out.write('$number 0 obj\n$body\nendobj\n');
  }
  final xref = utf8.encode(out.toString()).length;
  out.write('xref\n0 5\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF');
  return Uint8List.fromList(utf8.encode(out.toString()));
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  required DocumentSourceLoader loader,
  DocumentFileAction? download,
  Size size = const Size(1000, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDocumentViewer(
              context,
              documentId: 'synthetic-document',
              loadSource: loader,
              download: download,
              openExternally: (name, mime, bytes) async => true,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
}

void main() {
  testWidgets('image viewer shows original bytes and downloads unchanged', (
    tester,
  ) async {
    Uint8List? downloaded;
    await _pumpViewer(
      tester,
      loader: (_) async => LibrarySource(
        fileName: 'synthetic.png',
        mimeType: 'image/png',
        bytes: _png,
      ),
      download: (name, mime, bytes) async {
        expect(name, 'synthetic.png');
        expect(mime, 'image/png');
        downloaded = bytes;
        return true;
      },
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsWidgets);
    expect(find.text('synthetic.png'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloaded, orderedEquals(_png));
    await tester.tap(find.byTooltip('Close document'));
    await tester.pumpAndSettle();
    expect(find.text('synthetic.png'), findsNothing);
  });

  testWidgets('phone viewer is full screen with accessible close', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      size: const Size(390, 780),
      loader: (_) async => LibrarySource(
        fileName: 'phone.png',
        mimeType: 'image/png',
        bytes: _png,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('Close document'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF uses local in-app renderer with page and zoom controls', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      loader: (_) async => LibrarySource(
        fileName: 'synthetic.pdf',
        mimeType: 'application/pdf',
        bytes: _smallPdf(),
      ),
    );
    await tester.pump();
    expect(find.byType(PdfViewer), findsOneWidget);
    expect(find.byTooltip('Next page'), findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
  });

  testWidgets('loading, disconnected provider and retry are distinct', (
    tester,
  ) async {
    final pending = Completer<LibrarySource>();
    var calls = 0;
    await _pumpViewer(
      tester,
      loader: (_) {
        calls++;
        if (calls == 1) return pending.future;
        return Future.value(
          LibrarySource(
            fileName: 'restored.png',
            mimeType: 'image/png',
            bytes: _png,
          ),
        );
      },
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(
      const LibraryServiceException(
        'The storage connection needs to be reconnected.',
        providerDisconnected: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('The storage connection needs to be reconnected.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('restored.png'), findsOneWidget);
  });

  testWidgets('unsupported type offers download without external preview', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      loader: (_) async => LibrarySource(
        fileName: 'notes.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList([65]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Preview is not available'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Open externally'), findsNothing);
  });
}
