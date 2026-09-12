import 'dart:js_interop';
import 'dart:typed_data';

Future<bool> openExternalLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  window.open(uri.toString().toJS, '_blank'.toJS, 'noopener,noreferrer'.toJS);
  return true;
}

Future<bool> downloadDocument(
  String name,
  String mimeType,
  Uint8List bytes,
) async {
  final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final anchor = document.createElement('a'.toJS);
  final safeMime =
      {
        'application/pdf',
        'image/jpeg',
        'image/png',
      }.contains(mimeType.toLowerCase())
      ? mimeType.toLowerCase()
      : 'application/octet-stream';
  final href = createObjectUrl(
    LibraryBlob(
      <JSUint8Array>[bytes.toJS].toJS,
      LibraryBlobOptions()..type = safeMime.toJS,
    ),
  );
  anchor.setAttribute('href'.toJS, href);
  anchor.setAttribute('download'.toJS, safeName.toJS);
  anchor.setAttribute('rel'.toJS, 'noopener'.toJS);
  document.body.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
    await Future<void>.delayed(const Duration(seconds: 1));
    revokeObjectUrl(href);
  }
  return true;
}

Future<bool> openDocumentExternally(
  String name,
  String mimeType,
  Uint8List bytes,
) async {
  final safeMime = mimeType.toLowerCase();
  if (!{'application/pdf', 'image/jpeg', 'image/png'}.contains(safeMime)) {
    return false;
  }
  final href = createObjectUrl(
    LibraryBlob(
      <JSUint8Array>[bytes.toJS].toJS,
      LibraryBlobOptions()..type = safeMime.toJS,
    ),
  );
  window.open(href, '_blank'.toJS, 'noopener,noreferrer'.toJS);
  Future<void>.delayed(
    const Duration(seconds: 30),
    () => revokeObjectUrl(href),
  );
  return true;
}

@JS('window')
external LibraryWindow get window;

@JS('document')
external LibraryDocumentObject get document;

@JS('URL.createObjectURL')
external JSString createObjectUrl(LibraryBlob blob);

@JS('URL.revokeObjectURL')
external void revokeObjectUrl(JSString url);

@JS('Blob')
extension type LibraryBlob._(JSObject _) implements JSObject {
  external LibraryBlob(JSArray<JSUint8Array> parts, LibraryBlobOptions options);
}

@JS('Object')
extension type LibraryBlobOptions._(JSObject _) implements JSObject {
  external LibraryBlobOptions();
  external set type(JSString value);
}

extension type LibraryWindow(JSObject _) implements JSObject {
  external JSAny? open(JSString url, JSString target, JSString features);
}

extension type LibraryDocumentObject(JSObject _) implements JSObject {
  external LibraryElement createElement(JSString name);
  external LibraryElement get body;
}

extension type LibraryElement(JSObject _) implements JSObject {
  external void setAttribute(JSString name, JSString value);
  external JSAny? appendChild(LibraryElement child);
  external void click();
  external void remove();
}
