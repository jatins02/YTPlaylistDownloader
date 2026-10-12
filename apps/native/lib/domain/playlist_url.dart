import 'failure.dart';

final class PlaylistUrl {
  const PlaylistUrl._(this.id);

  factory PlaylistUrl.parse(String input) {
    const hosts = {
      'youtube.com',
      'www.youtube.com',
      'music.youtube.com',
      'm.youtube.com',
    };
    final uri = Uri.tryParse(input.trim());
    final List<String>? values;
    try {
      values = uri?.queryParametersAll['list'];
    } on FormatException {
      throw const AppFailure(
        FailureCode.invalidPlaylist,
        'Enter a valid YouTube playlist link.',
      );
    }
    if (uri == null ||
        uri.scheme != 'https' ||
        !hosts.contains(uri.host.toLowerCase()) ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        !{'/playlist', '/watch'}.contains(uri.path) ||
        values == null ||
        values.length != 1 ||
        !RegExp(r'^[A-Za-z0-9_-]{10,100}$').hasMatch(values.single) ||
        values.single.startsWith('RD')) {
      throw const AppFailure(
        FailureCode.invalidPlaylist,
        'Enter an HTTPS YouTube playlist link. Automatic mixes are unsupported.',
      );
    }
    return PlaylistUrl._(values.single);
  }

  final String id;
  String get canonical => 'https://www.youtube.com/playlist?list=$id';
}
