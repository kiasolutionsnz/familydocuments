import 'dart:async';
import 'dart:js_interop';

import '../../core/navigation/history_location.dart';

import 'inbox_navigation.dart';
import 'models/inbox_models.dart';

InboxNavigation createPlatformInboxNavigation() => _WebInboxNavigation();

class _WebInboxNavigation implements InboxNavigation {
  _WebInboxNavigation() {
    listener = ((JSAny? _) => controller.add(current)).toJS;
    window.addEventListener('popstate'.toJS, listener);
  }
  final controller = StreamController<InboxLocation>.broadcast();
  late final JSFunction listener;
  @override
  InboxLocation get current {
    final value = historyLocation(window.history.state?.dartify());
    return InboxLocation.parse(value.startsWith('inbox') ? value : 'inbox');
  }

  @override
  Stream<InboxLocation> get changes => controller.stream;
  @override
  void open(InboxLocation location) {
    window.history.pushState(
      historyWithLocation(
        window.history.state?.dartify(),
        location.value,
      ).jsify(),
      ''.toJS,
    );
    controller.add(location);
  }

  @override
  void replace(InboxLocation location) {
    window.history.replaceState(
      historyWithLocation(
        window.history.state?.dartify(),
        location.value,
      ).jsify(),
      ''.toJS,
    );
    controller.add(location);
  }

  @override
  void dispose() {
    window.removeEventListener('popstate'.toJS, listener);
    controller.close();
  }
}

@JS('window')
external InboxWindow get window;

extension type InboxWindow(JSObject _) implements JSObject {
  external InboxHistory get history;
  external void addEventListener(JSString type, JSFunction listener);
  external void removeEventListener(JSString type, JSFunction listener);
}

extension type InboxHistory(JSObject _) implements JSObject {
  external JSAny? get state;
  external void pushState(JSAny? data, JSString title);
  external void replaceState(JSAny? data, JSString title);
}
