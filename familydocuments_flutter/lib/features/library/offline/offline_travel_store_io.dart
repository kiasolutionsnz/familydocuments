import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'offline_travel_models.dart';

OfflineTravelStore createOfflineTravelStore({required String accountId}) =>
    IoOfflineTravelStore(accountId: accountId);

Future<OfflineTravelStore?> openLastOfflineTravelStore() async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  const storage = FlutterSecureStorage();
  final accountScope = await storage.read(
    key: IoOfflineTravelStore.lastScopeKey,
  );
  if (accountScope == null ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScope)) {
    return null;
  }
  final store = IoOfflineTravelStore.fromAccountScope(
    accountScope: accountScope,
    secureStorage: storage,
  );
  return (await store.listAll()).isEmpty ? null : store;
}

class IoOfflineTravelStore implements OfflineTravelStore {
  IoOfflineTravelStore({
    required String accountId,
    FlutterSecureStorage? secureStorage,
  }) : _accountScope = sha256.convert(utf8.encode(accountId)).toString(),
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  IoOfflineTravelStore.fromAccountScope({
    required String accountScope,
    FlutterSecureStorage? secureStorage,
  }) : _accountScope = accountScope,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _manifestName = 'manifest.enc';
  static const lastScopeKey = 'fd_offline_travel_last_scope_v1';
  final String _accountScope;
  final FlutterSecureStorage _secureStorage;
  final Cipher _cipher = FlutterCryptography.defaultInstance.aesGcm();

  @override
  bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}travel_offline_v1${Platform.pathSeparator}$_accountScope',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<SecretKey> _key() async {
    final keyName = 'fd_offline_travel_key_v1_$_accountScope';
    final stored = await _secureStorage.read(key: keyName);
    if (stored != null) return SecretKey(base64Url.decode(stored));
    final key = await _cipher.newSecretKey();
    final bytes = await key.extractBytes();
    await _secureStorage.write(key: keyName, value: base64UrlEncode(bytes));
    return SecretKey(bytes);
  }

  Future<Uint8List> _encrypt(List<int> clear, String purpose) async {
    final box = await _cipher.encrypt(
      clear,
      secretKey: await _key(),
      aad: utf8.encode('familydocuments:$purpose:v1'),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'nonce': base64UrlEncode(box.nonce),
          'cipher': base64UrlEncode(box.cipherText),
          'mac': base64UrlEncode(box.mac.bytes),
        }),
      ),
    );
  }

  Future<Uint8List> _decrypt(List<int> encoded, String purpose) async {
    final value = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
    final clear = await _cipher.decrypt(
      SecretBox(
        base64Url.decode(value['cipher'].toString()),
        nonce: base64Url.decode(value['nonce'].toString()),
        mac: Mac(base64Url.decode(value['mac'].toString())),
      ),
      secretKey: await _key(),
      aad: utf8.encode('familydocuments:$purpose:v1'),
    );
    return Uint8List.fromList(clear);
  }

  Future<List<OfflineTravelDocument>> _manifest() async {
    final file = File(
      '${(await _directory()).path}${Platform.pathSeparator}$_manifestName',
    );
    if (!await file.exists()) return [];
    final clear = await _decrypt(await file.readAsBytes(), 'manifest');
    final values = jsonDecode(utf8.decode(clear)) as List;
    return values
        .map(
          (item) => OfflineTravelDocument.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  Future<void> _writeManifest(List<OfflineTravelDocument> values) async {
    final directory = await _directory();
    final target = File(
      '${directory.path}${Platform.pathSeparator}$_manifestName',
    );
    final temporary = File('${target.path}.tmp');
    final clear = utf8.encode(
      jsonEncode(values.map((item) => item.toJson()).toList()),
    );
    await temporary.writeAsBytes(
      await _encrypt(clear, 'manifest'),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  String _safeId(String value) =>
      base64UrlEncode(utf8.encode(value)).replaceAll('=', '');

  Future<File> _file(String documentId) async => File(
    '${(await _directory()).path}${Platform.pathSeparator}${_safeId(documentId)}.enc',
  );

  @override
  Future<List<OfflineTravelDocument>> list(String tripId) async {
    if (!supported) return const [];
    await purgeExpired();
    return (await _manifest()).where((item) => item.tripId == tripId).toList()
      ..sort((a, b) => a.title.compareTo(b.title));
  }

  @override
  Future<List<OfflineTravelDocument>> listAll() async {
    if (!supported) return const [];
    await purgeExpired();
    return await _manifest()
      ..sort((a, b) {
        final trip = a.tripTitle.compareTo(b.tripTitle);
        return trip == 0 ? a.title.compareTo(b.title) : trip;
      });
  }

  @override
  Future<void> save({
    required String tripId,
    required String tripTitle,
    required String documentId,
    required String title,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) async {
    if (!supported) {
      throw UnsupportedError(
        'Secure offline travel packs require Android or iOS.',
      );
    }
    if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
      throw StateError(
        'Only non-empty travel documents up to 20 MB can be stored offline.',
      );
    }
    if (!expiresAt.isAfter(DateTime.now())) {
      throw StateError('Expiry must be in the future.');
    }
    final target = await _file(documentId);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(
      await _encrypt(bytes, 'document:$documentId'),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    await _secureStorage.write(key: lastScopeKey, value: _accountScope);
    final values = await _manifest();
    values.removeWhere((item) => item.documentId == documentId);
    values.add(
      OfflineTravelDocument(
        documentId: documentId,
        tripId: tripId,
        tripTitle: tripTitle,
        title: title,
        fileName: fileName,
        mimeType: mimeType,
        savedAt: DateTime.now(),
        expiresAt: expiresAt,
      ),
    );
    await _writeManifest(values);
  }

  @override
  Future<OfflineTravelFile?> read(String documentId) async {
    if (!supported) return null;
    await purgeExpired();
    final document = (await _manifest())
        .where((item) => item.documentId == documentId)
        .firstOrNull;
    if (document == null) return null;
    final file = await _file(documentId);
    if (!await file.exists()) return null;
    return OfflineTravelFile(
      document: document,
      bytes: await _decrypt(await file.readAsBytes(), 'document:$documentId'),
    );
  }

  @override
  Future<void> remove(String documentId) async {
    if (!supported) return;
    final values = await _manifest();
    values.removeWhere((item) => item.documentId == documentId);
    final file = await _file(documentId);
    if (await file.exists()) await file.delete();
    await _writeManifest(values);
  }

  @override
  Future<int> purgeExpired() async {
    if (!supported) return 0;
    final values = await _manifest();
    final expired = values.where((item) => item.expired).toList();
    if (expired.isEmpty) return 0;
    for (final item in expired) {
      final file = await _file(item.documentId);
      if (await file.exists()) await file.delete();
    }
    values.removeWhere((item) => item.expired);
    await _writeManifest(values);
    return expired.length;
  }
}
