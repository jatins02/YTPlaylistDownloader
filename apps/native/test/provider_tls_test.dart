import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/metadata/provider_transport.dart';

const certificate = 'test/fixtures/tls/server-cert.pem';
const key = 'test/fixtures/tls/server-key.pem';

SecurityContext trustFixture() =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certificate);

void main() {
  test(
    'DNS-pinned connection encrypts bytes and verifies the hostname',
    () async {
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(key);
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final received = Completer<String>();
      final subscription = server.listen((socket) {
        socket.listen((bytes) {
          received.complete(String.fromCharCodes(bytes));
          socket.destroy();
        }, onError: received.completeError);
      }, onError: received.completeError);
      Socket? socket;
      try {
        final task = SafeProviderTransport.secureTask(
          await Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
          'provider.test',
          context: trustFixture(),
        );
        socket = await task.socket.timeout(const Duration(seconds: 5));
        expect(socket, isA<SecureSocket>());
        expect((socket as SecureSocket).peerCertificate, isNotNull);
        socket.write('encrypted provider request');
        await socket.flush();
        expect(
          await received.future.timeout(const Duration(seconds: 5)),
          'encrypted provider request',
        );
      } finally {
        socket?.destroy();
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test(
    'a trusted certificate for another hostname cannot accept a request',
    () async {
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey(key);
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      var receivedApplicationBytes = false;
      final subscription = server.listen((socket) {
        socket.listen((_) => receivedApplicationBytes = true, onError: (_) {});
      }, onError: (_) {});
      final task = SafeProviderTransport.secureTask(
        await Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
        'wrong.test',
        context: trustFixture(),
      );
      try {
        await expectLater(
          task.socket.timeout(const Duration(seconds: 5)),
          throwsA(isA<HandshakeException>()),
        );
        expect(receivedApplicationBytes, isFalse);
      } finally {
        task.cancel();
        await subscription.cancel();
        await server.close();
      }
    },
  );

  test(
    'cancellation closes a connection stalled during the TLS handshake',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen(accepted.complete);
      final task = SafeProviderTransport.secureTask(
        await Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
        'provider.test',
        context: trustFixture(),
      );
      final result = expectLater(
        task.socket.timeout(const Duration(seconds: 5)),
        throwsA(anything),
      );
      final peer = await accepted.future;
      try {
        task.cancel();
        await result;
      } finally {
        peer.destroy();
        await subscription.cancel();
        await server.close();
      }
    },
  );
}
