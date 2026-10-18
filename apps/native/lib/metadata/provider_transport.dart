import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/failure.dart';

final class RequestScope {
  RequestScope({this.stopped});
  final bool Function()? stopped;
  final Set<HttpClient> _clients = {};
  bool cancelled = false;
  void check() {
    if (cancelled || stopped?.call() == true) {
      cancel();
      throw const AppFailure(
        FailureCode.operationCancelled,
        'Details preparation stopped.',
      );
    }
  }

  void cancel() {
    cancelled = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }

  Future<void> wait(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      check();
      final remaining = end.difference(DateTime.now());
      await Future<void>.delayed(
        remaining > const Duration(milliseconds: 100)
            ? const Duration(milliseconds: 100)
            : remaining,
      );
    }
    check();
  }
}

final class ProviderReply {
  const ProviderReply(
    this.status,
    this.bytes, {
    this.location,
    this.retryAfter,
    this.contentType,
  });
  final int status;
  final Uint8List bytes;
  final String? location, retryAfter, contentType;
  Future<Object?> json() => Isolate.run(() => jsonDecode(utf8.decode(bytes)));
}

abstract interface class ProviderTransport {
  Future<ProviderReply> request(
    Uri uri,
    RequestScope scope, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    int maxBytes = 256 * 1024,
  });
}

/// Provider-specific HTTPS destinations and DNS-pinned sockets. Redirects are
/// returned to the artwork adapter for revalidation; authorization never follows.
final class SafeProviderTransport implements ProviderTransport {
  static void validate(Uri uri, {bool authenticated = false}) {
    final host = uri.host.toLowerCase();
    final trusted =
        host == 'api.groq.com' ||
        host == 'musicbrainz.org' ||
        host == 'coverartarchive.org' ||
        host == 'archive.org' ||
        host.endsWith('.archive.org');
    if (!trusted ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.fragment.isNotEmpty ||
        uri.host.endsWith('.') ||
        (authenticated &&
            (host != 'api.groq.com' ||
                uri.path != '/openai/v1/chat/completions'))) {
      throw const AppFailure(
        FailureCode.artworkInvalid,
        'An untrusted provider destination was rejected.',
      );
    }
  }

  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    if (b.length == 4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && (b[1] == 168 || b[1] == 0)) ||
          (b[0] == 192 && b[1] == 2) ||
          (b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51)) ||
          (b[0] == 203 && b[1] == 0 && b[2] == 113));
    }
    // Ordinary global unicast only. Conservatively exclude IETF protocol/
    // transition space as well as both documentation ranges; those prefixes
    // must not turn a trusted hostname into a local/embedded-address route.
    // https://www.iana.org/assignments/iana-ipv6-special-registry/
    return b.length == 16 &&
        (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
        !(b[0] == 0x20 && b[1] == 0x02) &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
        !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
  }

  @override
  Future<ProviderReply> request(
    Uri uri,
    RequestScope scope, {
    Map<String, String> headers = const {},
    Map<String, Object?>? body,
    int maxBytes = 256 * 1024,
  }) async {
    // HTTP header names are case-insensitive. Snapshot caller-owned headers
    // before DNS/socket awaits so later mutation cannot bypass this boundary.
    final requestHeaders = Map<String, String>.unmodifiable(headers);
    final authenticated = requestHeaders.keys.any(
      (name) => name.toLowerCase() == 'authorization',
    );
    validate(uri, authenticated: authenticated);
    scope.check();
    if (maxBytes < 1 || maxBytes > 5 * 1024 * 1024) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'Invalid provider byte limit.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = true
      ..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (target, proxyHost, proxyPort) async {
      scope.check();
      validate(target, authenticated: authenticated);
      final addresses = await InternetAddress.lookup(target.host)
          .timeout(const Duration(seconds: 5));
      scope.check();
      if (addresses.isEmpty || addresses.any((a) => !publicAddress(a))) {
        throw const AppFailure(
          FailureCode.artworkInvalid,
          'A nonpublic provider address was rejected.',
        );
      }
      // HttpClient does not wrap custom connectionFactory sockets in TLS.
      // Pin the TCP address, then verify TLS/SNI against the original hostname.
      return secureTask(
        await Socket.startConnect(addresses.first, target.port),
        target.host,
      );
    };
    scope._clients.add(client);
    var timedOut = false;
    final deadline = Timer(const Duration(seconds: 45), () {
      timedOut = true;
      client.close(force: true);
    });
    final cancellation = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (scope.stopped?.call() == true) scope.cancel();
    });
    try {
      Future<ProviderReply> operation() async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        request.followRedirects = false;
        requestHeaders.forEach(request.headers.set);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        scope.check();
        if (response.contentLength > maxBytes) {
          throw const AppFailure(
            FailureCode.limitExceeded,
            'Provider response exceeded its byte limit.',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          scope.check();
          if (bytes.length + chunk.length > maxBytes) {
            throw const AppFailure(
              FailureCode.limitExceeded,
              'Provider response exceeded its byte limit.',
            );
          }
          bytes.add(chunk);
        }
        return ProviderReply(
          response.statusCode,
          bytes.takeBytes(),
          location: response.headers.value(HttpHeaders.locationHeader),
          retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
          contentType: response.headers.contentType?.mimeType,
        );
      }

      return await operation().timeout(const Duration(seconds: 45));
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      scope.check();
      throw const AppFailure(
        FailureCode.processTimeout,
        'The provider request timed out.',
        retryable: true,
      );
    } catch (_) {
      scope.check();
      if (timedOut) {
        throw const AppFailure(
          FailureCode.processTimeout,
          'The provider request timed out.',
          retryable: true,
        );
      }
      throw const AppFailure(
        FailureCode.aiUnavailable,
        'The provider could not be reached. Audio is preserved.',
        retryable: true,
      );
    } finally {
      deadline.cancel();
      cancellation.cancel();
      scope._clients.remove(client);
      client.close(force: true);
    }
  }

  /// Wrap an already connected address without resolving the hostname again.
  /// The request factory validates every DNS address before calling this.
  static ConnectionTask<Socket> secureTask(
    ConnectionTask<Socket> connection,
    String hostname, {
    SecurityContext? context,
  }) {
    Socket? active;
    var cancelled = false;
    final socket = connection.socket.then((tcp) async {
      active = tcp;
      if (cancelled) {
        tcp.destroy();
        throw const AppFailure(
          FailureCode.operationCancelled,
          'Details preparation stopped.',
        );
      }
      try {
        final secure = await SecureSocket.secure(
          tcp,
          host: hostname,
          context: context,
        );
        active = secure;
        if (cancelled) {
          secure.destroy();
          throw const AppFailure(
            FailureCode.operationCancelled,
            'Details preparation stopped.',
          );
        }
        return secure;
      } catch (_) {
        tcp.destroy();
        rethrow;
      }
    });
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      connection.cancel();
      active?.destroy();
    });
  }
}

Duration retryDelay(String? value) {
  final seconds = int.tryParse(value ?? '');
  if (seconds != null) return Duration(seconds: seconds.clamp(1, 86400));
  try {
    final time = HttpDate.parse(value ?? '');
    return Duration(
      seconds: time
          .difference(DateTime.now().toUtc())
          .inSeconds
          .clamp(1, 86400),
    );
  } catch (_) {
    return const Duration(seconds: 60);
  }
}
