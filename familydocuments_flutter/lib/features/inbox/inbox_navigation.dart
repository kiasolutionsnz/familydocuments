import 'dart:async';

import 'inbox_navigation_stub.dart'
    if (dart.library.html) 'inbox_navigation_web.dart'
    as platform;
import 'models/inbox_models.dart';

abstract class InboxNavigation {
  InboxLocation get current;
  Stream<InboxLocation> get changes;
  void open(InboxLocation location);
  void replace(InboxLocation location);
  void dispose();
}

InboxNavigation createInboxNavigation() =>
    platform.createPlatformInboxNavigation();
