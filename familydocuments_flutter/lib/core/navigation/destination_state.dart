import 'dart:async';

import 'destination_state_factory_stub.dart'
    if (dart.library.html) 'destination_state_factory_web.dart'
    as platform;

enum PrimaryDestination { home, timeline, library, inbox, reminders, lists }

PrimaryDestination destinationFromPath(String value) {
  final path = value
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^#?/?'), '')
      .split('/')
      .first;
  return PrimaryDestination.values.firstWhere(
    (destination) => destination.name == path,
    orElse: () => PrimaryDestination.home,
  );
}

abstract class DestinationState {
  PrimaryDestination get current;
  Stream<PrimaryDestination> get changes;
  void select(PrimaryDestination destination);
  void reset();
  void dispose();
}

DestinationState createDestinationState() =>
    platform.createPlatformDestinationState();
