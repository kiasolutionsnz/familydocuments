import 'dart:async';

import 'destination_state.dart';

DestinationState createPlatformDestinationState() => _MemoryDestinationState();

class _MemoryDestinationState implements DestinationState {
  final _changes = StreamController<PrimaryDestination>.broadcast();
  PrimaryDestination _current = PrimaryDestination.home;

  @override
  PrimaryDestination get current => _current;

  @override
  Stream<PrimaryDestination> get changes => _changes.stream;

  @override
  void select(PrimaryDestination destination) {
    if (_current == destination) return;
    _current = destination;
    _changes.add(destination);
  }

  @override
  void reset() => select(PrimaryDestination.home);

  @override
  void dispose() => _changes.close();
}
