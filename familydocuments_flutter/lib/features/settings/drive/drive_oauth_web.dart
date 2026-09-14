import 'dart:js_interop';

@JS('familyDocumentsDrive.prepare')
external JSPromise<JSAny?> _prepare();
@JS('familyDocumentsDrive.authorize')
external JSPromise<JSString> _authorize(JSString clientId);

Future<void> prepareDriveAuthorization() async {
  await _prepare().toDart;
}

Future<String> requestDriveAuthorization(String clientId) async =>
    (await _authorize(clientId.toJS).toDart).toDart;
