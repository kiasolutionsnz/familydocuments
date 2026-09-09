import 'dart:convert';
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
  final href = 'data:$mimeType;base64,${base64Encode(bytes)}';
  anchor.setAttribute('href'.toJS, href.toJS);
  anchor.setAttribute('download'.toJS, safeName.toJS);
  anchor.setAttribute('rel'.toJS, 'noopener'.toJS);
  anchor.click();
  return true;
}

@JS('window')
external LibraryWindow get window;

@JS('document')
external LibraryDocumentObject get document;

extension type LibraryWindow(JSObject _) implements JSObject {
  external JSAny? open(JSString url, JSString target, JSString features);
}

extension type LibraryDocumentObject(JSObject _) implements JSObject {
  external LibraryElement createElement(JSString name);
}

extension type LibraryElement(JSObject _) implements JSObject {
  external void setAttribute(JSString name, JSString value);
  external void click();
}
