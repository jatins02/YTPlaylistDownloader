"""Offline DNS/TLS and redirect contracts for the CLI artwork client."""
import socket
import ssl
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from stage0.core import CheckError
from stage0.providers import ArtworkClient, validate_artwork_url

FIXTURES = Path(__file__).resolve().parents[1] / 'apps/native/test/fixtures/tls'


class ArtworkTransportTests(unittest.TestCase):
    def test_slow_dns_stops_without_opening_a_connection(self):
        release = threading.Event()
        def lookup(*args, **kwargs):
            release.wait(2)
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443))]
        start = time.monotonic()
        try:
            with self.assertRaises(CheckError) as raised:
                validate_artwork_url('https://archive.org/cover', lookup, timeout=.02)
            self.assertEqual(raised.exception.code, 'ARTWORK_TIMEOUT')
            self.assertLess(time.monotonic() - start, 1)
        finally:
            release.set()

    def test_redirect_is_revalidated_before_another_socket_is_opened(self):
        response = MagicMock(status=302, headers={'Location': 'https://evil.example/cover'})
        pool = MagicMock()
        pool.urlopen.return_value.__enter__.return_value = response
        public = lambda *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443))]
        with patch.dict('os.environ', {'MUSICBRAINZ_CONTACT': 'fixture@example.test'}), ArtworkClient() as client, \
             patch('stage0.providers.validate_artwork_url', side_effect=lambda url, **kw: validate_artwork_url(url, public, **kw)), \
             patch('stage0.providers.artwork_connection', return_value=pool) as connect:
            with self.assertRaises(CheckError) as raised:
                client.fetch('https://archive.org/cover')
            self.assertEqual(raised.exception.code, 'ARTWORK_URL_INVALID')
            connect.assert_called_once()
            self.assertEqual(connect.call_args.args[:2], ('archive.org', '8.8.8.8'))
            self.assertEqual(pool.urlopen.call_args.kwargs['headers']['Host'], 'archive.org')

    def test_pinned_tcp_keeps_tls_hostname_verification(self):
        # The fixture is trusted only inside this test, never by the app/CLI.
        import urllib3
        for host in ['provider.test', 'wrong.test']:
            with self.subTest(host=host):
                listener = socket.socket()
                listener.bind(('127.0.0.1', 0))
                listener.listen(1)
                listener.settimeout(5)
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(FIXTURES / 'server-cert.pem', FIXTURES / 'server-key.pem')
                received, sni = [], []
                context.set_servername_callback(lambda sock, name, ctx: sni.append(name))
                def serve():
                    try:
                        peer, _ = listener.accept()
                        with peer, context.wrap_socket(peer, server_side=True) as secure:
                            received.append(secure.recv(8192))
                            secure.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\ncover')
                    except (ssl.SSLError, OSError):
                        pass
                server = threading.Thread(target=serve, daemon=True)
                server.start()
                addresses = []
                def connect(address, *args, **kwargs):
                    addresses.append(address)
                    return socket.create_connection(listener.getsockname(), timeout=3)
                try:
                    with patch('certifi.where', return_value=str(FIXTURES / 'server-cert.pem')), \
                         patch('urllib3.util.connection.create_connection', side_effect=connect), \
                         patch('stage0.providers.validate_artwork_url', return_value=['8.8.8.8']), \
                         patch.dict('os.environ', {'MUSICBRAINZ_CONTACT': 'fixture@example.test'}), \
                         ArtworkClient() as client:
                        if host == 'provider.test':
                            self.assertEqual(client.fetch('https://' + host + '/cover'), b'cover')
                            self.assertIn(b'Host: provider.test', received[0])
                        else:
                            with self.assertRaises(urllib3.exceptions.SSLError):
                                client.fetch('https://' + host + '/cover')
                            self.assertFalse(any(received))
                    self.assertEqual(addresses, [('8.8.8.8', 443)])
                    self.assertEqual(sni, [host])
                finally:
                    listener.close()
                    server.join(timeout=5)
                    self.assertFalse(server.is_alive())
