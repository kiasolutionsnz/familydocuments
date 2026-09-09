import 'dart:async';

import 'library_navigation.dart';
import 'models/library_models.dart';

LibraryNavigation createPlatformLibraryNavigation() =>
    _MemoryLibraryNavigation();

class _MemoryLibraryNavigation implements LibraryNavigation {
  LibraryLocation value = const LibraryLocation.top();
  final controller = StreamController<LibraryLocation>.broadcast();
  @override
  LibraryLocation get current => value;
  @override
  Stream<LibraryLocation> get changes => controller.stream;
  @override
  void open(LibraryLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void replace(LibraryLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void dispose() => controller.close();
}
