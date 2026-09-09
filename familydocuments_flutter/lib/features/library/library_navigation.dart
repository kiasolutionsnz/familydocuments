import 'dart:async';

import 'library_navigation_stub.dart'
    if (dart.library.html) 'library_navigation_web.dart'
    as platform;
import 'models/library_models.dart';

abstract class LibraryNavigation {
  LibraryLocation get current;
  Stream<LibraryLocation> get changes;
  void open(LibraryLocation location);
  void replace(LibraryLocation location);
  void dispose();
}

LibraryNavigation createLibraryNavigation() =>
    platform.createPlatformLibraryNavigation();
