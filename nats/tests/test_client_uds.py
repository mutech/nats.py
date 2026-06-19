"""
Tests for the nats+uds:// (UNIX domain socket) transport.

The parsing tests need no server. The integration test enables UDS purely
through a generated config file (a `uds { }` listener block plus a
peer-credential authorization rule), so it reuses the NATSD harness unchanged
and requires a nats-server build with UDS support (the snats fork).
"""

import os
import tempfile
import unittest

import nats
import nats.errors
from nats.aio.client import Client as NATS
from nats.aio.transport import Transport, UnixTransport
from tests.utils import NATSD, async_test, start_natsd

SOCKET_PATH = "/tmp/nats-py-uds-it.sock"
CONFIG_PATH = "/tmp/nats-py-uds-it.conf"
UDS_URL = "nats+uds://" + SOCKET_PATH


def _write_uds_config(path: str, socket_path: str) -> None:
    """Minimal UDS server config: a socket listener plus a peer-cred rule for
    the current uid. UDS connections have no default-allow policy, so an
    explicit (allow-all) permissions block is required."""
    uid = os.getuid()
    with open(path, "w") as f:
        f.write(
            f"""uds {{
  path: "{socket_path}"
}}
authorization {{
  users = [
    {{
      user: "uds-test"
      uds {{ match {{ uid: {uid} }} }}
      permissions {{
        publish {{ allow: [ ">" ] }}
        subscribe {{ allow: [ ">" ] }}
      }}
    }}
  ]
}}
"""
        )


class UDSParseTest(unittest.TestCase):
    """Server-free coverage of the nats+uds:// scheme wiring."""

    def test_parse_uds_url(self):
        uri = NATS._parse_server_uri("nats+uds:///run/snats/snats.sock")
        self.assertEqual(uri.scheme, "nats+uds")
        self.assertEqual(uri.path, "/run/snats/snats.sock")
        self.assertIsNone(uri.hostname)

    def test_parse_uds_url_with_user(self):
        uri = NATS._parse_server_uri("nats+uds://user:pass@/tmp/x.sock")
        self.assertEqual(uri.scheme, "nats+uds")
        self.assertEqual(uri.path, "/tmp/x.sock")
        self.assertEqual(uri.username, "user")
        self.assertEqual(uri.password, "pass")

    def test_non_uds_url_unaffected(self):
        uri = NATS._parse_server_uri("nats://localhost:4222")
        self.assertEqual(uri.scheme, "nats")
        self.assertEqual(uri.hostname, "localhost")
        self.assertEqual(uri.port, 4222)

    def test_setup_server_pool_accepts_uds(self):
        nc = NATS()
        nc._setup_server_pool("nats+uds:///tmp/x.sock")
        self.assertEqual(len(nc._server_pool), 1)
        self.assertEqual(nc._server_pool[0].uri.scheme, "nats+uds")

    def test_uds_not_mixable_with_websocket(self):
        nc = NATS()
        with self.assertRaises(nats.errors.Error):
            nc._setup_server_pool(["nats+uds:///tmp/x.sock", "ws://localhost:80"])

    def test_unix_transport_is_a_transport(self):
        self.assertTrue(issubclass(UnixTransport, Transport))


class UDSServerTestCase(unittest.TestCase):
    """End-to-end over a real nats-server (UDS fork) on a socket."""

    def setUp(self):
        import asyncio

        self.loop = asyncio.new_event_loop()
        _write_uds_config(CONFIG_PATH, SOCKET_PATH)
        # Keep a TCP/monitoring port so the harness readiness probe (/varz)
        # works; the tests themselves connect over the socket.
        self.natsd = NATSD(port=4555, http_port=8555, config_file=CONFIG_PATH)
        start_natsd(self.natsd)

    def tearDown(self):
        self.natsd.stop()
        self.loop.close()
        for path in (SOCKET_PATH, CONFIG_PATH):
            try:
                os.remove(path)
            except OSError:
                pass

    @async_test
    async def test_uds_connect_and_pub_sub(self):
        nc = await nats.connect(UDS_URL)
        self.assertTrue(nc.is_connected)

        sub = await nc.subscribe("uds.echo")
        await nc.flush()
        await nc.publish("uds.echo", b"hello over uds")
        msg = await sub.next_msg(timeout=2)
        self.assertEqual(msg.data, b"hello over uds")

        await nc.close()

    @async_test
    async def test_uds_request_reply(self):
        nc = await nats.connect(UDS_URL)

        async def handler(msg):
            await msg.respond(b"pong")

        await nc.subscribe("uds.service", cb=handler)
        await nc.flush()

        resp = await nc.request("uds.service", b"ping", timeout=2)
        self.assertEqual(resp.data, b"pong")

        await nc.close()


if __name__ == "__main__":
    unittest.main()
