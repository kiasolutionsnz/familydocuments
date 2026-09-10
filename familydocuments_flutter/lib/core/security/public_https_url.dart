bool isPublicHttpsUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    return false;
  }
  final parts = host.split('.');
  if (parts.length == 4 && parts.every((part) => int.tryParse(part) != null)) {
    final numbers = parts.map(int.parse).toList();
    if (numbers.any((value) => value < 0 || value > 255)) return false;
    return false;
  }
  return !host.contains(':') && host.contains('.');
}

String? publicHttpsHostname(String value) =>
    isPublicHttpsUrl(value) ? Uri.parse(value).host : null;
