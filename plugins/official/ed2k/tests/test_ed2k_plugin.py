from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


PLUGIN_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN_DIR))

from ed2k_plugin import (  # noqa: E402
    SERVER_MET_URLS,
    AmuleBackendProvider,
    AmuleClient,
    AmuleTask,
    BackendSession,
    Ed2kLink,
    Ed2kService,
    NetworkState,
    PluginFailure,
    _bounded_int,
    _fetch_network_asset,
    _is_server_met,
    _split_urls,
)


FILE_HASH = "ABCDEF0123456789ABCDEF0123456789"
LINK = f"ed2k://|file|Hanabi%20Archive.bin|10|{FILE_HASH}|/"


class FakeAmuleClient:
    def __init__(self, tasks=None, network=None):
        self.tasks = dict(tasks or {})
        self.commands = []
        self.network = network
        self.connect_calls = 0

    def show_downloads(self):
        return dict(self.tasks)

    def connection_state(self):
        if self.network is None:
            raise PluginFailure(-32020, "no daemon")
        return self.network

    def connect(self):
        self.connect_calls += 1

    def run(self, command, require_success=False):
        self.commands.append((command, require_success))
        if command.startswith("Add "):
            link = Ed2kLink.parse(command[4:])
            self.tasks[link.file_hash] = AmuleTask(
                link.file_hash, link.file_name, 0, "Waiting"
            )
        elif command.startswith("Pause "):
            file_hash = command.split()[-1]
            task = self.tasks[file_hash]
            self.tasks[file_hash] = AmuleTask(
                task.file_hash, task.file_name, task.progress, "Paused"
            )
        elif command.startswith("Resume "):
            file_hash = command.split()[-1]
            task = self.tasks[file_hash]
            self.tasks[file_hash] = AmuleTask(
                task.file_hash, task.file_name, task.progress, "Waiting"
            )
        elif command.startswith("Cancel "):
            self.tasks.pop(command.split()[-1], None)
        return "Succeeded! Connection established\n > Operation was successful."


class FakeHttpResponse:
    def __init__(self, payload: bytes, status: int):
        self.stream = io.BytesIO(payload)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, size=-1):
        return self.stream.read(size)

    def getcode(self):
        return self.status


class Ed2kLinkTests(unittest.TestCase):
    def test_parses_file_link(self):
        link = Ed2kLink.parse(LINK.lower())

        self.assertEqual(link.file_hash, FILE_HASH)
        self.assertEqual(link.file_name, "hanabi archive.bin")
        self.assertEqual(link.size, 10)
        self.assertIn(FILE_HASH, link.normalized)

    def test_rejects_server_link(self):
        with self.assertRaisesRegex(PluginFailure, "Only ED2K file links"):
            Ed2kLink.parse("ed2k://|server|127.0.0.1|4661|/")

    def test_rejects_line_breaks(self):
        with self.assertRaisesRegex(PluginFailure, "cannot contain line breaks"):
            Ed2kLink.parse(LINK.replace("Hanabi", "Hanabi\nStatus"))


class AmuleClientTests(unittest.TestCase):
    def test_parses_show_download_queue(self):
        output = (
            "This is amulecmd 3.0.0\r\n"
            "Succeeded! Connection established to aMule 3.0.0\r\n"
            f" > {FILE_HASH} Hanabi Archive.bin\r\n"
            " > \t [37.5%]    2/   5 - Downloading - 001.part.met - Auto [Hi]\r\n"
        )
        client = AmuleClient("amulecmd", "127.0.0.1", 4712, "secret")
        with patch.object(client, "run", return_value=output):
            tasks = client.show_downloads()

        task = tasks[FILE_HASH]
        self.assertEqual(task.file_name, "Hanabi Archive.bin")
        self.assertEqual(task.progress, 0.375)
        self.assertEqual(task.state, "Downloading")
        self.assertEqual(task.part_file, "001.part.met")

    def test_parses_source_counts_from_download_queue(self):
        output = (
            "Succeeded! Connection established to aMule 3.0.0\r\n"
            f" > {FILE_HASH} Hanabi Archive.bin\r\n"
            " > \t [ 0.0%]    0/  12 - Waiting - 001.part.met - Auto [Hi]\r\n"
        )
        client = AmuleClient("amulecmd", "127.0.0.1", 4712, "secret")
        with patch.object(client, "run", return_value=output):
            task = client.show_downloads()[FILE_HASH]

        self.assertEqual(task.active_sources, 0)
        self.assertEqual(task.total_sources, 12)
        self.assertEqual(task.state, "Waiting")

    def test_connection_failure_is_detected_even_with_zero_exit_code(self):
        completed = SimpleNamespace(
            returncode=0,
            stdout=b"Creating client...\nConnection Failed. Unable to connect",
            stderr=b"",
        )
        client = AmuleClient("amulecmd", "127.0.0.1", 4712, "secret")
        with patch("ed2k_plugin.subprocess.run", return_value=completed):
            with self.assertRaisesRegex(PluginFailure, "Cannot connect"):
                client.run("Status")


class Ed2kServiceTests(unittest.TestCase):
    def backend(self, client, incoming=None):
        return lambda: BackendSession(client, incoming, True)

    def test_create_adds_and_pauses_task(self):
        client = FakeAmuleClient()
        service = Ed2kService(self.backend(client), now=lambda: 100)

        result = service.create(
            {
                "intent": {"type": "ed2k", "normalizedValue": LINK},
                "saveDir": "D:/Downloads",
                "startPaused": True,
            },
            "hanabi.official.ed2k",
        )

        self.assertEqual(result["status"], "paused")
        self.assertEqual(result["taskId"], f"plugin:hanabi.official.ed2k:{FILE_HASH}")
        self.assertEqual(client.commands[0][0], f"Add {LINK}")
        self.assertEqual(client.commands[1][0], f"Pause {FILE_HASH}")
        self.assertTrue(all(required for _, required in client.commands))

    def test_create_is_idempotent_by_ed2k_hash(self):
        task = AmuleTask(FILE_HASH, "Hanabi Archive.bin", 0.2, "Waiting")
        client = FakeAmuleClient({FILE_HASH: task})
        service = Ed2kService(self.backend(client), now=lambda: 100)

        result = service.create(
            {"intent": {"type": "ed2k", "normalizedValue": LINK}}
        )

        self.assertEqual(result["status"], "pending")
        self.assertEqual(client.commands, [])

    def test_create_does_not_pause_an_already_completed_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming = root / "incoming"
            incoming.mkdir()
            (incoming / "Hanabi Archive.bin").write_bytes(b"0123456789")
            client = FakeAmuleClient()
            service = Ed2kService(self.backend(client, incoming), now=lambda: 100)

            result = service.create(
                {
                    "intent": {"type": "ed2k", "normalizedValue": LINK},
                    "saveDir": str(root / "destination"),
                    "startPaused": True,
                },
                "hanabi.official.ed2k",
            )

            self.assertEqual(result["status"], "completed")
            self.assertEqual(client.commands, [])

    def test_status_maps_progress_and_sizes(self):
        task = AmuleTask(FILE_HASH, "Hanabi Archive.bin", 0.4, "Downloading")
        client = FakeAmuleClient({FILE_HASH: task})
        service = Ed2kService(self.backend(client))

        result = service.status(
            {
                "pluginData": {
                    "ed2kHash": FILE_HASH,
                    "fileName": "Hanabi Archive.bin",
                    "totalSize": 10,
                    "saveDir": "D:/Downloads",
                }
            }
        )

        self.assertEqual(result["status"], "downloading")
        self.assertEqual(result["progress"], 0.4)
        self.assertEqual(result["downloadedSize"], 4)
        self.assertEqual(result["totalSize"], 10)

    def test_completed_file_moves_to_requested_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming = root / "incoming"
            destination = root / "destination"
            incoming.mkdir()
            (incoming / "Hanabi Archive.bin").write_bytes(b"0123456789")
            client = FakeAmuleClient()
            service = Ed2kService(self.backend(client, incoming), now=lambda: 100)

            result = service.status(
                {
                    "pluginData": {
                        "ed2kHash": FILE_HASH,
                        "fileName": "Hanabi Archive.bin",
                        "totalSize": 10,
                        "saveDir": str(destination),
                        "incomingDir": str(incoming),
                    }
                }
            )

            final_path = destination / "Hanabi Archive.bin"
            self.assertEqual(result["status"], "completed")
            self.assertEqual(result["filePath"], str(final_path))
            self.assertTrue(final_path.is_file())
            self.assertFalse((incoming / "Hanabi Archive.bin").exists())

    def test_same_sized_destination_does_not_mask_completed_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming = root / "incoming"
            destination = root / "destination"
            incoming.mkdir()
            destination.mkdir()
            source = incoming / "Hanabi Archive.bin"
            existing = destination / "Hanabi Archive.bin"
            source.write_bytes(b"new-result")
            existing.write_bytes(b"old-result")
            client = FakeAmuleClient()
            service = Ed2kService(self.backend(client, incoming), now=lambda: 100)

            result = service.status(
                {
                    "pluginData": {
                        "ed2kHash": FILE_HASH,
                        "fileName": "Hanabi Archive.bin",
                        "totalSize": 10,
                        "saveDir": str(destination),
                        "incomingDir": str(incoming),
                    }
                }
            )

            alternate = destination / "Hanabi Archive (ABCDEF01).bin"
            self.assertEqual(result["status"], "completed")
            self.assertEqual(result["filePath"], str(alternate))
            self.assertEqual(existing.read_bytes(), b"old-result")
            self.assertEqual(alternate.read_bytes(), b"new-result")
            self.assertFalse(source.exists())

    def test_missing_task_uses_grace_period_then_fails(self):
        client = FakeAmuleClient()
        data = {
            "ed2kHash": FILE_HASH,
            "fileName": "Hanabi Archive.bin",
            "totalSize": 10,
            "missingSinceEpoch": 100,
        }
        pending = Ed2kService(self.backend(client), now=lambda: 110).status(
            {"pluginData": data}
        )
        failed = Ed2kService(self.backend(client), now=lambda: 131).status(
            {"pluginData": data}
        )

        self.assertEqual(pending["status"], "pending")
        self.assertEqual(failed["status"], "failed")

    def test_status_reports_sources_and_derives_speed_between_polls(self):
        clock = iter([1000, 1010])
        task = AmuleTask(
            FILE_HASH, "Hanabi Archive.bin", 0.1, "Downloading", "", 3, 9
        )
        client = FakeAmuleClient({FILE_HASH: task})
        service = Ed2kService(self.backend(client), now=lambda: next(clock))
        params = {
            "pluginData": {
                "ed2kHash": FILE_HASH,
                "fileName": "Hanabi Archive.bin",
                "totalSize": 10_000_000,
            }
        }

        first = service.status(params)
        client.tasks[FILE_HASH] = AmuleTask(
            FILE_HASH, "Hanabi Archive.bin", 0.2, "Downloading", "", 4, 9
        )
        second = service.status({"pluginData": first["pluginData"]})

        self.assertEqual(first["speed"], 0)
        self.assertEqual(first["peerCount"], 3)
        self.assertEqual(first["seeders"], 9)
        self.assertEqual(second["speed"], 100_000)
        self.assertEqual(second["statusDetail"], "4/9 sources")

    def test_pending_status_explains_why_no_sources_are_available(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            task = AmuleTask(FILE_HASH, "Hanabi Archive.bin", 0.0, "Waiting")
            client = FakeAmuleClient(
                {FILE_HASH: task},
                network=NetworkState(
                    ed2k_connected=False,
                    kad_connected=False,
                    firewalled=False,
                    summary="",
                ),
            )
            service = Ed2kService(
                lambda: BackendSession(client, None, True, state_dir),
                now=lambda: 5000,
            )

            result = service.status(
                {
                    "pluginData": {
                        "ed2kHash": FILE_HASH,
                        "fileName": "Hanabi Archive.bin",
                        "totalSize": 10,
                    }
                }
            )

        self.assertEqual(result["status"], "pending")
        self.assertIn("searching for sources", result["statusDetail"])
        self.assertIn("not connected", result["statusDetail"])
        self.assertEqual(client.connect_calls, 1)

    def test_unrecognised_status_output_does_not_trigger_reconnects(self):
        with tempfile.TemporaryDirectory() as temporary:
            task = AmuleTask(FILE_HASH, "Hanabi Archive.bin", 0.0, "Waiting")
            client = FakeAmuleClient(
                {FILE_HASH: task},
                network=NetworkState(
                    ed2k_connected=False,
                    kad_connected=False,
                    firewalled=False,
                    summary="",
                    recognized=False,
                ),
            )
            service = Ed2kService(
                lambda: BackendSession(client, None, True, Path(temporary)),
                now=lambda: 5000,
            )
            result = service.status(
                {
                    "pluginData": {
                        "ed2kHash": FILE_HASH,
                        "fileName": "Hanabi Archive.bin",
                        "totalSize": 10,
                    }
                }
            )

        self.assertEqual(result["statusDetail"], "searching for sources")
        self.assertEqual(client.connect_calls, 0)

    def test_remove_is_idempotent_when_task_is_missing(self):
        client = FakeAmuleClient()
        service = Ed2kService(self.backend(client))
        result = service.remove(
            {
                "pluginData": {
                    "ed2kHash": FILE_HASH,
                    "fileName": "Hanabi Archive.bin",
                    "totalSize": 10,
                }
            }
        )

        self.assertEqual(result["status"], "removed")
        self.assertEqual(client.commands, [])


class BackendProviderTests(unittest.TestCase):
    def test_resumes_and_verifies_engine_archive(self):
        archive_stream = io.BytesIO()
        with zipfile.ZipFile(archive_stream, "w") as bundle:
            bundle.writestr("amule-portable/bin/amuled.exe", b"daemon")
            bundle.writestr("amule-portable/bin/amulecmd.exe", b"command")
            bundle.writestr("amule-portable/share/LICENSE.md", b"license")
        archive = archive_stream.getvalue()
        split = len(archive) // 2
        asset = {
            "name": "amule-test",
            "url": "https://example.invalid/amule.zip",
            "sha256": hashlib.sha256(archive).hexdigest(),
            "size": len(archive),
        }

        with tempfile.TemporaryDirectory() as temporary:
            provider = AmuleBackendProvider(
                plugin_dir=PLUGIN_DIR,
                data_dir=temporary,
                log_dir=Path(temporary) / "logs",
                environ={},
            )
            part = Path(temporary) / "engine" / ".downloads" / "amule-test.zip.part"
            part.parent.mkdir(parents=True)
            part.write_bytes(archive[:split])
            with patch.object(provider, "_engine_asset", return_value=asset), patch(
                "ed2k_plugin.urllib.request.urlopen",
                return_value=FakeHttpResponse(archive[split:], 206),
            ):
                engine = provider._install_engine()

            self.assertEqual(engine.amuled.read_bytes(), b"daemon")
            self.assertEqual(engine.amulecmd.read_bytes(), b"command")
            self.assertTrue((engine.amuled.parents[1] / "share" / "LICENSE.md").is_file())
            self.assertFalse(part.exists())

    def test_managed_config_hashes_password_and_binds_ec_to_loopback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "core" / "amule.conf"
            AmuleBackendProvider._write_amule_config(
                config_path,
                password="plain-secret",
                ec_port=4712,
                client_port=4662,
                udp_port=4672,
                core_dir=root / "core",
                incoming_dir=root / "incoming",
                temporary_dir=root / "temporary",
                auto_connect=True,
            )
            content = config_path.read_text(encoding="utf-8")

        self.assertIn("ECAddress=127.0.0.1", content)
        self.assertIn(
            f"ECPassword={hashlib.md5(b'plain-secret').hexdigest()}", content
        )
        self.assertNotIn("ECPassword=plain-secret", content)
        # Without these a fresh profile never obtains a server list and every
        # task stays in "Waiting" forever.
        self.assertIn("Serverlist=1", content)
        self.assertIn("AddServerListFromServer=1", content)
        self.assertIn("UPnPEnabled=1", content)

    def test_bootstrap_seeds_server_list_and_kad_nodes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provider = AmuleBackendProvider(
                plugin_dir=PLUGIN_DIR,
                data_dir=root,
                log_dir=root / "logs",
                environ={},
            )
            core_dir = root / "core"
            core_dir.mkdir()
            payload = b"\xe0" + (5).to_bytes(4, "little") + b"\x00" * 64
            with patch(
                "ed2k_plugin.urllib.request.urlopen",
                side_effect=lambda *_, **__: FakeHttpResponse(payload, 200),
            ):
                provider._bootstrap_network_files(core_dir, {})

            self.assertEqual((core_dir / "server.met").read_bytes(), payload)
            self.assertEqual((core_dir / "nodes.dat").read_bytes(), payload)

    def test_bootstrap_keeps_a_recent_file_and_survives_network_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            core_dir = Path(temporary)
            existing = core_dir / "server.met"
            existing.write_bytes(b"\xe0" + b"\x02" * 64)

            kept = _fetch_network_asset(existing, ("https://example.invalid/x",))
            with patch(
                "ed2k_plugin.urllib.request.urlopen",
                side_effect=OSError("offline"),
            ):
                failed = _fetch_network_asset(
                    core_dir / "nodes.dat", ("https://example.invalid/x",)
                )

            self.assertEqual(kept, "kept")
            self.assertTrue(failed.startswith("failed:"))
            self.assertFalse((core_dir / "nodes.dat").exists())

    def test_bootstrap_rejects_html_and_falls_through_to_a_valid_mirror(self):
        # server-met.de answers dl.php with an HTML page; writing that over
        # server.met leaves aMule with an unparsable list.
        html = b"\xef\xbb\xbf\r\n<!DOCTYPE html><html>rate limited</html>" + b" " * 64
        valid = b"\xe0" + (7).to_bytes(4, "little") + b"\x00" * 64
        responses = iter(
            [FakeHttpResponse(html, 200), FakeHttpResponse(valid, 200)]
        )

        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "server.met"
            with patch(
                "ed2k_plugin.urllib.request.urlopen",
                side_effect=lambda *_, **__: next(responses),
            ):
                outcome = _fetch_network_asset(
                    target,
                    ("http://broken.invalid/dl.php", "http://good.invalid/server.met"),
                    _is_server_met,
                )

            self.assertIn("good.invalid", outcome)
            self.assertEqual(target.read_bytes(), valid)

    def test_configured_sources_come_first_and_can_replace_the_defaults(self):
        with tempfile.TemporaryDirectory() as temporary:
            provider = AmuleBackendProvider(
                plugin_dir=PLUGIN_DIR,
                data_dir=Path(temporary),
                log_dir=Path(temporary) / "logs",
                environ={},
            )
            merged = provider._source_urls(
                {"serverMetUrls": ["http://mine.invalid/server.met"]},
                environment_name="AMULE_SERVER_MET_URL",
                config_names=("serverMetUrls", "serverMetUrl"),
                defaults_flag="useDefaultServerLists",
                defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
                fallbacks=SERVER_MET_URLS,
            )
            replaced = provider._source_urls(
                {
                    "useDefaultServerLists": False,
                    "serverMetUrl": "http://only.invalid/a.met http://only.invalid/a.met",
                },
                environment_name="AMULE_SERVER_MET_URL",
                config_names=("serverMetUrls", "serverMetUrl"),
                defaults_flag="useDefaultServerLists",
                defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
                fallbacks=SERVER_MET_URLS,
            )

        self.assertEqual(merged[0], "http://mine.invalid/server.met")
        self.assertEqual(merged[1:], SERVER_MET_URLS)
        self.assertEqual(replaced, ("http://only.invalid/a.met",))

    def test_query_string_urls_are_not_split_on_their_commas(self):
        parsed = _split_urls(
            "http://a.invalid/dl.php?load=min,gz\nhttps://b.invalid/server.met"
        )

        self.assertEqual(
            parsed,
            ["http://a.invalid/dl.php?load=min,gz", "https://b.invalid/server.met"],
        )


class SettingsTests(unittest.TestCase):
    def provider(self, root: Path) -> AmuleBackendProvider:
        return AmuleBackendProvider(
            plugin_dir=PLUGIN_DIR,
            data_dir=root,
            log_dir=root / "logs",
            environ={},
        )

    def test_settings_merge_into_config_without_dropping_other_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # 手写的键必须原样保留：设置页只认识自己声明的控件。
            (root / "config.json").write_text(
                json.dumps({"amuleHome": "C:/Tools/aMule", "startupTimeoutSeconds": 30}),
                encoding="utf-8",
            )

            result = self.provider(root).apply_settings({
                "enableUpnp": False,
                "maxSourcesPerFile": 500,
                "serverMetUrl": "  http://extra.invalid/server.met  ",
                "unrelatedControl": "ignored",
            })
            stored = json.loads((root / "config.json").read_text(encoding="utf-8"))

        self.assertEqual(stored["amuleHome"], "C:/Tools/aMule")
        self.assertEqual(stored["startupTimeoutSeconds"], 30)
        self.assertFalse(stored["enableUpnp"])
        self.assertEqual(stored["maxSourcesPerFile"], 500)
        self.assertEqual(stored["serverMetUrl"], "http://extra.invalid/server.met")
        self.assertNotIn("unrelatedControl", stored)
        self.assertTrue(result["restartRequired"])

    def test_listen_port_setting_is_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            provider = self.provider(Path(temporary))
            provider.apply_settings({"listenPort": "4662"})
            fixed = provider._load_config()["listenPort"]
            # 特权端口不接受，退回自动分配
            provider.apply_settings({"listenPort": "80"})
            privileged = provider._load_config()["listenPort"]
            provider.apply_settings({"listenPort": ""})
            cleared = provider._load_config()["listenPort"]

        self.assertEqual(fixed, 4662)
        self.assertEqual(privileged, 0)
        self.assertEqual(cleared, 0)

    def test_settings_can_replace_the_built_in_lists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provider = self.provider(root)
            provider.apply_settings({
                "serverMetUrl": "http://only.invalid/a.met\nhttp://only.invalid/b.met",
                "useDefaultServerLists": False,
            })
            urls = provider._source_urls(
                provider._load_config(),
                environment_name="AMULE_SERVER_MET_URL",
                config_names=("serverMetUrls", "serverMetUrl"),
                defaults_flag="useDefaultServerLists",
                defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
                fallbacks=SERVER_MET_URLS,
            )

        self.assertEqual(
            urls, ("http://only.invalid/a.met", "http://only.invalid/b.met")
        )

    def test_settings_can_append_to_the_built_in_lists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provider = self.provider(root)
            provider.apply_settings({"serverMetUrl": "http://extra.invalid/a.met"})
            urls = provider._source_urls(
                provider._load_config(),
                environment_name="AMULE_SERVER_MET_URL",
                config_names=("serverMetUrls", "serverMetUrl"),
                defaults_flag="useDefaultServerLists",
                defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
                fallbacks=SERVER_MET_URLS,
            )

        self.assertEqual(urls[0], "http://extra.invalid/a.met")
        self.assertEqual(urls[1:], SERVER_MET_URLS)

    def test_applied_settings_reach_the_generated_amule_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            provider = self.provider(root)
            provider.apply_settings({"enableUpnp": False, "maxSourcesPerFile": 300})
            config = provider._load_config()

            path = root / "core" / "amule.conf"
            AmuleBackendProvider._write_amule_config(
                path,
                password="secret",
                ec_port=4712,
                client_port=4662,
                udp_port=4672,
                core_dir=root / "core",
                incoming_dir=root / "incoming",
                temporary_dir=root / "temp",
                auto_connect=True,
                upnp=provider._bool_setting("AMULE_UPNP", config, "enableUpnp", True),
                max_sources=_bounded_int(
                    config.get("maxSourcesPerFile"), 1000, 20, 1000
                ),
            )
            content = path.read_text(encoding="utf-8")

        self.assertIn("UPnPEnabled=0", content)
        self.assertIn("MaxSourcesPerFile=300", content)

    def test_refresh_ignores_the_freshness_check(self):
        valid = b"\xe0" + (9).to_bytes(4, "little") + b"\x00" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            core_dir = root / "core"
            core_dir.mkdir()
            # 刚写入的文件会被引导逻辑判定为「新鲜」而跳过下载。
            (core_dir / "server.met").write_bytes(
                b"\xe0" + (1).to_bytes(4, "little") + b"\x00" * 64
            )
            with patch(
                "ed2k_plugin.urllib.request.urlopen",
                side_effect=lambda *_, **__: FakeHttpResponse(valid, 200),
            ):
                result = self.provider(root).refresh_network_lists()

            self.assertIn("updated", result["serverMet"])
            self.assertEqual((core_dir / "server.met").read_bytes(), valid)


class ProtocolTests(unittest.TestCase):
    def test_main_returns_structured_error_without_starting_backend(self):
        request = {
            "jsonrpc": "2.0",
            "id": "test-1",
            "method": "hanabi.download.create",
            "params": {"intent": {"type": "magnet", "normalizedValue": "x"}},
        }
        environment = dict(os.environ)
        environment["HANABI_PLUGIN_ID"] = "hanabi.official.ed2k"
        completed = subprocess.run(
            [sys.executable, str(PLUGIN_DIR / "main.py")],
            input=json.dumps(request),
            text=True,
            capture_output=True,
            check=False,
            cwd=PLUGIN_DIR,
            env=environment,
            timeout=10,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        response = json.loads(completed.stdout)
        self.assertEqual(response["error"]["code"], -32010)
        self.assertIn("Unsupported intent type", response["error"]["message"])

    def test_response_is_utf8_even_without_pythonioencoding(self):
        # 宿主按 UTF-8 解码 stdout。开发机上常设的 PYTHONIOENCODING=utf-8
        # 会掩盖问题，从资源管理器启动的正式版本没有这个变量：那时 print()
        # 会按 GBK 编码，带中文文件名的响应直接让宿主解码失败。
        request = {
            "jsonrpc": "2.0",
            "id": "utf8-1",
            # 这个方法会原样回显传入的值，且不需要启动 aMule。
            "method": "onSettingsChanged",
            "params": {"serverMetUrl": "http://例子.测试/server.met"},
        }
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ)
            environment["HANABI_PLUGIN_ID"] = "hanabi.official.ed2k"
            environment["HANABI_PLUGIN_DATA_DIR"] = temporary
            environment["HANABI_PLUGIN_LOG_DIR"] = temporary
            environment.pop("PYTHONIOENCODING", None)
            environment.pop("PYTHONUTF8", None)
            completed = subprocess.run(
                [sys.executable, str(PLUGIN_DIR / "main.py")],
                input=json.dumps(request).encode("utf-8"),
                capture_output=True,
                check=False,
                cwd=PLUGIN_DIR,
                env=environment,
                timeout=30,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        # 关键断言：原始字节必须是合法 UTF-8，而不是本地编码
        decoded = completed.stdout.decode("utf-8")
        response = json.loads(decoded)
        self.assertEqual(
            response["result"]["applied"]["serverMetUrl"],
            "http://例子.测试/server.met",
        )


if __name__ == "__main__":
    unittest.main()
