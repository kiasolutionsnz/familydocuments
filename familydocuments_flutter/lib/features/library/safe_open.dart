import 'dart:typed_data';

import '../../core/security/public_https_url.dart';

import 'safe_open_stub.dart'
    if (dart.library.html) 'safe_open_web.dart'
    as platform;

Future<bool> openExternalLink(String url) => isPublicHttpsUrl(url)
    ? platform.openExternalLink(url)
    : Future<bool>.value(false);
Future<bool> downloadDocument(String name, String mimeType, Uint8List bytes) =>
    platform.downloadDocument(name, mimeType, bytes);
Future<bool> openDocumentExternally(
  String name,
  String mimeType,
  Uint8List bytes,
) => platform.openDocumentExternally(name, mimeType, bytes);
