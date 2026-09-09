import 'dart:async';
import 'dart:js_interop';

import 'library_navigation.dart';
import 'models/library_models.dart';

LibraryNavigation createPlatformLibraryNavigation() => _WebLibraryNavigation();

class _WebLibraryNavigation implements LibraryNavigation {
  _WebLibraryNavigation() {
    listener = ((JSAny? _) => controller.add(current)).toJS;
    window.addEventListener('popstate'.toJS, listener);
  }
  final controller = StreamController<LibraryLocation>.broadcast();
  late final JSFunction listener;
  @override
  LibraryLocation get current {
    final value = (window.history.state?.dartify() ?? '').toString();
    return LibraryLocation.parse(
      value.startsWith('library') ? value : 'library',
    );
  }

  @override
  Stream<LibraryLocation> get changes => controller.stream;
  @override
  void open(LibraryLocation location) {
    window.history.pushState(location.value.toJS, ''.toJS);
    controller.add(location);
  }

  @override
  void replace(LibraryLocation location) {
    window.history.replaceState(location.value.toJS, ''.toJS);
    controller.add(location);
  }

  @override
  void dispose() {
    window.removeEventListener('popstate'.toJS, listener);
    controller.close();
  }
}

@JS('window')
external LibraryWindow get window;

extension type LibraryWindow(JSObject _) implements JSObject {
  external LibraryHistory get history;
  external void addEventListener(JSString type, JSFunction listener);
  external void removeEventListener(JSString type, JSFunction listener);
}

extension type LibraryHistory(JSObject _) implements JSObject {
  external JSAny? get state;
  external void pushState(JSAny? data, JSString title);
  external void replaceState(JSAny? data, JSString title);
}
