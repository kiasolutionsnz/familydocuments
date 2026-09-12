import 'dart:async';
import 'dart:js_interop';

import 'destination_state.dart';
import 'history_location.dart';

DestinationState createPlatformDestinationState() => _WebDestinationState();

class _WebDestinationState implements DestinationState {
  _WebDestinationState() {
    _historyListener = ((JSAny? _) {
      _changes.add(current);
    }).toJS;
    _window.addEventListener('popstate'.toJS, _historyListener);
  }

  final _changes = StreamController<PrimaryDestination>.broadcast();
  late final JSFunction _historyListener;

  @override
  PrimaryDestination get current =>
      destinationFromPath(historyLocation(_window.history.state?.dartify()));

  @override
  Stream<PrimaryDestination> get changes => _changes.stream;

  @override
  void select(PrimaryDestination destination) {
    if (current == destination) return;
    _window.history.pushState(
      historyWithLocation(
        _window.history.state?.dartify(),
        destination.name,
      ).jsify(),
      ''.toJS,
    );
    _changes.add(destination);
  }

  @override
  void reset() {
    _window.history.replaceState(
      historyWithLocation(
        _window.history.state?.dartify(),
        PrimaryDestination.home.name,
      ).jsify(),
      ''.toJS,
    );
    _changes.add(PrimaryDestination.home);
  }

  @override
  void dispose() {
    _window.removeEventListener('popstate'.toJS, _historyListener);
    _changes.close();
  }
}

@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external _History get history;
  external void addEventListener(JSString type, JSFunction listener);
  external void removeEventListener(JSString type, JSFunction listener);
}

extension type _History(JSObject _) implements JSObject {
  external JSAny? get state;
  external void pushState(JSAny? data, JSString title);
  external void replaceState(JSAny? data, JSString title);
}
