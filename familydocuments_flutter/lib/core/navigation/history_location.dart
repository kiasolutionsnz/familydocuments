// Keep application navigation separate from Flutter's browser-history fields.
String historyLocation(Object? state) {
  if (state is String) return state; // Previously stored same-tab destinations.
  if (state is Map) {
    final location = state['familydocumentsLocation'];
    if (location is String) return location;
  }
  return '';
}

Map<String, Object?> historyWithLocation(Object? state, String location) => {
  if (state is Map)
    for (final entry in state.entries)
      if (entry.key is String) entry.key as String: entry.value,
  'familydocumentsLocation': location,
};
