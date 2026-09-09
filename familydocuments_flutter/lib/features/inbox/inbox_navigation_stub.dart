import 'dart:async';

import 'inbox_navigation.dart';
import 'models/inbox_models.dart';

InboxNavigation createPlatformInboxNavigation() => _MemoryInboxNavigation();

class _MemoryInboxNavigation implements InboxNavigation {
  InboxLocation value = const InboxLocation();
  final controller = StreamController<InboxLocation>.broadcast();
  @override
  InboxLocation get current => value;
  @override
  Stream<InboxLocation> get changes => controller.stream;
  @override
  void open(InboxLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void replace(InboxLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void dispose() => controller.close();
}
