import 'dart:typed_data';

import 'safe_open_stub.dart'
    if (dart.library.html) 'safe_open_web.dart'
    as platform;

Future<bool> openExternalLink(String url) => platform.openExternalLink(url);
Future<bool> downloadDocument(String name, String mimeType, Uint8List bytes) =>
    platform.downloadDocument(name, mimeType, bytes);
