from __future__ import annotations

import configparser
import hashlib
import json
import locale
import os
import platform
import re
import secrets
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping


PLUGIN_ID = "hanabi.official.ed2k"
MAX_ENGINE_ARCHIVE_BYTES = 64 * 1024 * 1024
MISSING_TASK_GRACE_SECONDS = 30

# A freshly created aMule config dir has neither a server list nor Kad contacts,
# so the daemon logs "No valid servers to which to connect found in server list"
# and every task stays in "Waiting" forever. aMule only refreshes those files by
# itself when Serverlist=1 is set, and even then not before the first connect
# attempt, so the plugin seeds both files before the daemon starts.
# 每个地址都经过实测：返回值必须能通过 _is_server_met / _is_nodes_dat 校验。
# 站点挂掉或改成 HTML 提示页是常事，所以按顺序尝试，并且写入前校验格式。
SERVER_MET_URLS = (
    "https://upd.emule-security.org/server.met",
    "http://ed2k.2x4u.de/v1s4vbaf/micro/server.met",
    "http://upd.emule-security.org/server.met",
    "https://www.gruk.org/server.met",
)
KAD_NODES_URLS = (
    "https://upd.emule-security.org/nodes.dat",
    "http://upd.emule-security.org/nodes.dat",
)
MAX_NETWORK_ASSET_BYTES = 4 * 1024 * 1024
MIN_NETWORK_ASSET_BYTES = 32
NETWORK_ASSET_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
NETWORK_ASSET_RETRY_SECONDS = 10 * 60
NETWORK_ASSET_TIMEOUT_SECONDS = 8

# Connection probes cost one amulecmd process, so they are shared by every task
# through a state file instead of running once per status poll.
NETWORK_PROBE_INTERVAL_SECONDS = 20
RECONNECT_INTERVAL_SECONDS = 60
STALLED_SAMPLE_SECONDS = 45

ENGINE_ASSETS = {
    "win-x64": {
        "name": "amule-3.0.0-windows-x64",
        "url": "https://github.com/amule-project/amule/releases/download/"
        "3.0.0/aMule-3.0.0-Windows-x64.zip",
        "sha256": "9b5a6a17a1039c5b1d6ea15adb471bf5495691d73c57a5eda54d696e03f7c299",
        "size": 47759209,
    },
    "win-arm64": {
        "name": "amule-3.0.0-windows-arm64",
        "url": "https://github.com/amule-project/amule/releases/download/"
        "3.0.0/aMule-3.0.0-Windows-arm64.zip",
        "sha256": "5eef52539f47f397d801191670a302464048a99374458df3f068ec8743c7b71b",
        "size": 36263885,
    },
}

ED2K_FILE_PATTERN = re.compile(
    r"^ed2k://\|file\|(?P<name>[^|]+)\|(?P<size>[0-9]+)\|"
    r"(?P<hash>[0-9a-f]{32})\|(?P<extra>(?:[^|]*\|)*)/$",
    re.IGNORECASE,
)
HASH_PATTERN = re.compile(r"^[0-9A-F]{32}$")
QUEUE_HEADER_PATTERN = re.compile(r"^\s*>\s*([0-9A-F]{32})\s+(.+?)\s*$", re.IGNORECASE)
# amulecmd right-aligns the percentage, so anything below 10% arrives as
# "[ 0.0%]". The unpadded form only ever matched tasks already past 10%, which
# left every freshly queued task parsed as a bare header with no state.
PROGRESS_PATTERN = re.compile(r"\[\s*(\d+(?:\.\d+)?)\s*%\s*\]")
# "[37.5%]    2/   5 - Downloading" -> 2 transferring sources out of 5 known ones.
SOURCES_PATTERN = re.compile(r"\]\s*(\d+)\s*/\s*(\d+)")


class PluginFailure(RuntimeError):
    def __init__(
        self,
        code: int,
        message: str,
        data: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = dict(data) if data is not None else None


@dataclass(frozen=True)
class Ed2kLink:
    normalized: str
    file_name: str
    size: int
    file_hash: str

    @classmethod
    def parse(cls, value: str) -> "Ed2kLink":
        if "\r" in value or "\n" in value:
            raise PluginFailure(-32010, "ED2K links cannot contain line breaks")
        match = ED2K_FILE_PATTERN.fullmatch(value.strip())
        if match is None:
            raise PluginFailure(
                -32010,
                "Only ED2K file links are supported; server and server-list links are rejected",
            )
        size = int(match.group("size"))
        if size <= 0:
            raise PluginFailure(-32010, "ED2K file size must be greater than zero")
        encoded_name = match.group("name")
        try:
            decoded_name = urllib.parse.unquote(encoded_name, errors="strict")
        except (UnicodeDecodeError, ValueError) as error:
            raise PluginFailure(-32010, "ED2K file name is not valid UTF-8") from error
        file_name = _safe_file_name(decoded_name)
        file_hash = match.group("hash").upper()
        parts = value.strip().split("|")
        parts[0] = "ed2k://"
        parts[1] = "file"
        parts[4] = file_hash
        return cls(
            normalized="|".join(parts),
            file_name=file_name,
            size=size,
            file_hash=file_hash,
        )


@dataclass(frozen=True)
class EnginePaths:
    amuled: Path
    amulecmd: Path


@dataclass(frozen=True)
class AmuleTask:
    file_hash: str
    file_name: str
    progress: float
    state: str
    part_file: str = ""
    active_sources: int = 0
    total_sources: int = 0


@dataclass(frozen=True)
class NetworkState:
    ed2k_connected: bool
    kad_connected: bool
    firewalled: bool
    summary: str
    recognized: bool = True

    @property
    def offline(self) -> bool:
        # Only claim the daemon is offline when the status output was actually
        # understood: an unrecognised layout must not trigger reconnect churn.
        return self.recognized and not self.ed2k_connected and not self.kad_connected


@dataclass(frozen=True)
class BackendSession:
    client: "AmuleClient"
    incoming_dir: Path | None
    managed: bool
    state_dir: Path | None = None


class AmuleClient:
    def __init__(
        self,
        executable: str | os.PathLike[str],
        host: str,
        port: int,
        password: str,
        *,
        timeout: float = 12,
    ) -> None:
        self.executable = Path(executable)
        self.host = host
        self.port = port
        self.password = password
        self.timeout = timeout

    def run(self, command: str, *, require_success: bool = False) -> str:
        arguments = [
            str(self.executable),
            f"--host={self.host}",
            f"--port={self.port}",
            f"--password={self.password}",
            "--locale=en",
            f"--command={command}",
        ]
        creation_flags = 0
        if os.name == "nt":
            creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        try:
            completed = subprocess.run(
                arguments,
                cwd=str(self.executable.parent),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=self.timeout,
                check=False,
                creationflags=creation_flags,
            )
        except subprocess.TimeoutExpired as error:
            raise PluginFailure(-32020, f"aMule command timed out: {command}") from error
        except OSError as error:
            raise PluginFailure(-32020, f"Failed to start amulecmd: {error}") from error

        output = _decode_process_output(completed.stdout, completed.stderr)
        if (
            completed.returncode != 0
            or "Connection Failed." in output
            or "Succeeded! Connection established" not in output
        ):
            raise PluginFailure(
                -32020,
                f"Cannot connect to aMule External Connections: {_last_output_line(output)}",
            )
        if require_success and "Operation was successful." not in output:
            raise PluginFailure(
                -32021,
                f"aMule command failed: {_last_output_line(output)}",
            )
        return output

    def show_downloads(self) -> dict[str, AmuleTask]:
        output = self.run("Show DL")
        tasks: dict[str, AmuleTask] = {}
        current_hash = ""
        current_name = ""
        for raw_line in output.splitlines():
            line = raw_line.rstrip("\r")
            header = QUEUE_HEADER_PATTERN.match(line)
            if header is not None:
                current_hash = header.group(1).upper()
                current_name = header.group(2).strip()
                tasks[current_hash] = AmuleTask(
                    file_hash=current_hash,
                    file_name=current_name,
                    progress=0,
                    state="waiting",
                )
                continue
            if not current_hash:
                continue
            progress_match = PROGRESS_PATTERN.search(line)
            if progress_match is None:
                continue
            segments = [segment.strip() for segment in line.split(" - ")]
            state = segments[1] if len(segments) >= 2 else "waiting"
            part_file = segments[2] if len(segments) >= 3 else ""
            sources = SOURCES_PATTERN.search(segments[0] if segments else line)
            tasks[current_hash] = AmuleTask(
                file_hash=current_hash,
                file_name=current_name,
                progress=max(0.0, min(float(progress_match.group(1)) / 100, 1.0)),
                state=state,
                part_file=part_file,
                active_sources=int(sources.group(1)) if sources else 0,
                total_sources=int(sources.group(2)) if sources else 0,
            )
        return tasks

    def connection_state(self) -> NetworkState:
        """Read ed2k/Kad connectivity from the daemon status output.

        amulecmd wording varies between builds, so unrecognised output is
        reported as such rather than being read as "disconnected".
        """
        output = self.run("Status")
        ed2k_connected = False
        kad_connected = False
        firewalled = False
        recognized = False
        details: list[str] = []
        for raw_line in output.splitlines():
            line = raw_line.strip(" >\t\r")
            lowered = line.lower()
            if "ed2k" in lowered and "connect" in lowered:
                ed2k_connected = "not connected" not in lowered
                recognized = True
                details.append(line)
            elif ("kad" in lowered or "kademlia" in lowered) and (
                "connect" in lowered or "running" in lowered
            ):
                kad_connected = (
                    "not connected" not in lowered and "not running" not in lowered
                )
                recognized = True
                details.append(line)
            if "firewall" in lowered or "lowid" in lowered or "low id" in lowered:
                firewalled = True
        return NetworkState(
            ed2k_connected=ed2k_connected,
            kad_connected=kad_connected,
            firewalled=firewalled,
            summary=" | ".join(details[:3]),
            recognized=recognized,
        )

    def verify_connection(self) -> None:
        self.run("Status")

    def connect(self) -> None:
        """Ask the daemon to (re)join both networks. Never fatal."""
        try:
            self.run("Connect")
        except PluginFailure:
            pass


class AmuleBackendProvider:
    def __init__(
        self,
        *,
        plugin_dir: str | os.PathLike[str] | None = None,
        data_dir: str | os.PathLike[str] | None = None,
        log_dir: str | os.PathLike[str] | None = None,
        environ: Mapping[str, str] | None = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.environ = dict(os.environ if environ is None else environ)
        module_dir = Path(__file__).resolve().parent
        self.plugin_dir = Path(
            plugin_dir or self.environ.get("HANABI_PLUGIN_DIR") or module_dir
        ).resolve()
        self.data_dir = Path(
            data_dir
            or self.environ.get("HANABI_PLUGIN_DATA_DIR")
            or (self.plugin_dir / ".hanabi-data")
        ).resolve()
        self.log_dir = Path(
            log_dir
            or self.environ.get("HANABI_PLUGIN_LOG_DIR")
            or (self.data_dir / "logs")
        ).resolve()
        self.sleep = sleep
        self._skip_running_session = False

    def invalidate(self) -> None:
        """Force the next session() call to re-check or restart the daemon."""
        self._skip_running_session = True

    def session(self) -> BackendSession:
        config = self._load_config()
        external_host = self._text_setting("AMULE_HOST", config, "amuleHost")
        if external_host:
            return self._external_session(config, external_host)

        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        with self._startup_lock():
            state = self._read_state()
            running = self._running_managed_session(state)
            if running is not None:
                return running

            engine = self._find_engine(config, state)
            if engine is None and self._bool_setting(
                "AMULE_AUTO_INSTALL", config, "autoInstallEngine", True
            ):
                engine = self._install_engine()
            if engine is None:
                raise PluginFailure(
                    -32020,
                    "aMule is unavailable. Allow the verified Windows engine download, "
                    "set AMULE_HOME, provide AMULED_PATH and AMULECMD_PATH, or configure "
                    "an external aMule EC endpoint.",
                )
            return self._start_managed(engine, config, state)

    def _load_config(self) -> dict[str, Any]:
        path = self.data_dir / "config.json"
        if not path.exists():
            return {}
        try:
            decoded = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PluginFailure(-32020, f"Invalid plugin config.json: {error}") from error
        if not isinstance(decoded, dict):
            raise PluginFailure(-32020, "Plugin config.json must contain an object")
        return decoded

    def _external_session(
        self, config: Mapping[str, Any], host: str
    ) -> BackendSession:
        command_path = self._text_setting(
            "AMULECMD_PATH", config, "amulecmdPath"
        )
        executable = Path(command_path).expanduser() if command_path else None
        if executable is None or not executable.is_file():
            discovered = shutil.which("amulecmd")
            executable = Path(discovered) if discovered else None
        if executable is None or not executable.is_file():
            raise PluginFailure(
                -32020, "External aMule mode requires AMULECMD_PATH or amulecmd in PATH"
            )
        port = _bounded_int(
            self._text_setting("AMULE_PORT", config, "amulePort"), 4712, 1, 65535
        )
        password = self._text_setting("AMULE_PASSWORD", config, "amulePassword")
        if not password:
            raise PluginFailure(-32020, "External aMule mode requires AMULE_PASSWORD")
        incoming = self._text_setting(
            "AMULE_INCOMING_DIR", config, "externalIncomingDir"
        )
        client = AmuleClient(executable, host, port, password)
        client.verify_connection()
        return BackendSession(
            client=client,
            incoming_dir=Path(incoming).expanduser() if incoming else None,
            managed=False,
            state_dir=self.data_dir,
        )

    def _read_state(self) -> dict[str, Any]:
        path = self.data_dir / "managed-runtime.json"
        if not path.exists():
            return {}
        try:
            decoded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return {}
        return decoded if isinstance(decoded, dict) else {}

    def _running_managed_session(
        self, state: Mapping[str, Any]
    ) -> BackendSession | None:
        if self._skip_running_session:
            self._skip_running_session = False
            return None
        try:
            executable = Path(str(state.get("amulecmd") or ""))
            password = str(state.get("password") or "")
            port = int(state.get("ecPort") or 0)
            incoming = Path(str(state.get("incomingDir") or ""))
            if not executable.is_file() or not password or port <= 0:
                return None
            # A TCP probe replaces an amulecmd "Status" round trip here: every
            # status poll used to spawn two processes just to reach the queue.
            # If the port answers but the daemon is wedged, the actual command
            # fails and the caller retries with a forced restart.
            if not _ec_port_responding(port):
                return None
            client = AmuleClient(executable, "127.0.0.1", port, password, timeout=8)
            return BackendSession(
                client=client,
                incoming_dir=incoming,
                managed=True,
                state_dir=self.data_dir,
            )
        except (OSError, TypeError, ValueError, PluginFailure):
            return None

    def _find_engine(
        self,
        config: Mapping[str, Any],
        state: Mapping[str, Any],
    ) -> EnginePaths | None:
        daemon_setting = self._text_setting("AMULED_PATH", config, "amuledPath")
        command_setting = self._text_setting(
            "AMULECMD_PATH", config, "amulecmdPath"
        )
        if daemon_setting and command_setting:
            direct = EnginePaths(
                Path(daemon_setting).expanduser(),
                Path(command_setting).expanduser(),
            )
            if direct.amuled.is_file() and direct.amulecmd.is_file():
                return direct

        candidates: list[Path] = []
        home_setting = self._text_setting("AMULE_HOME", config, "amuleHome")
        if home_setting:
            candidates.append(Path(home_setting).expanduser())
        state_daemon = str(state.get("amuled") or "")
        if state_daemon:
            candidates.append(Path(state_daemon).parent)
        candidates.extend([self.plugin_dir / "bin", self.plugin_dir / "amule"])
        engine_root = self.data_dir / "engine"
        if engine_root.is_dir():
            candidates.extend(sorted(engine_root.glob("*/bin")))
        for candidate in candidates:
            pair = _engine_pair(candidate)
            if pair is not None:
                return pair

        daemon = shutil.which("amuled")
        command = shutil.which("amulecmd")
        if daemon and command:
            return EnginePaths(Path(daemon), Path(command))
        return None

    def _install_engine(self) -> EnginePaths | None:
        asset = self._engine_asset()
        if asset is None:
            return None
        install_dir = self.data_dir / "engine" / str(asset["name"])
        existing = _engine_pair(install_dir / "bin")
        if existing is not None:
            return existing

        archive = self._download_asset(asset)
        actual_hash = _sha256_file(archive)
        if actual_hash != asset["sha256"]:
            archive.unlink(missing_ok=True)
            raise PluginFailure(
                -32020,
                "Downloaded aMule engine failed SHA-256 verification",
                {"expected": asset["sha256"], "actual": actual_hash},
            )

        temporary = install_dir.with_name(
            f".{install_dir.name}.extracting-{os.getpid()}-{secrets.token_hex(4)}"
        )
        temporary.mkdir(parents=True, exist_ok=False)
        try:
            with zipfile.ZipFile(archive) as bundle:
                for member in bundle.infolist():
                    parts = Path(member.filename.replace("\\", "/")).parts
                    if len(parts) <= 1:
                        continue
                    relative = Path(*parts[1:])
                    target = (temporary / relative).resolve()
                    if temporary.resolve() not in target.parents and target != temporary.resolve():
                        raise PluginFailure(-32020, "aMule archive contains an unsafe path")
                    if member.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(member) as source, target.open("wb") as output:
                        shutil.copyfileobj(source, output)
            pair = _engine_pair(temporary / "bin")
            if pair is None:
                raise PluginFailure(
                    -32020, "aMule archive does not contain amuled and amulecmd"
                )
            _write_json_atomic(
                temporary / "source.json",
                {
                    "url": asset["url"],
                    "sha256": asset["sha256"],
                    "downloadedAt": _utc_timestamp(),
                },
            )
            install_dir.parent.mkdir(parents=True, exist_ok=True)
            if install_dir.exists():
                for item in temporary.iterdir():
                    destination = install_dir / item.name
                    if destination.exists() and destination.is_dir():
                        shutil.rmtree(destination)
                    elif destination.exists():
                        destination.unlink()
                    item.replace(destination)
                temporary.rmdir()
            else:
                temporary.replace(install_dir)
        except (OSError, zipfile.BadZipFile) as error:
            raise PluginFailure(-32020, f"Failed to install aMule engine: {error}") from error
        finally:
            if temporary.exists():
                shutil.rmtree(temporary, ignore_errors=True)
        archive.unlink(missing_ok=True)
        return _engine_pair(install_dir / "bin")

    def _download_asset(self, asset: Mapping[str, Any]) -> Path:
        download_dir = self.data_dir / "engine" / ".downloads"
        download_dir.mkdir(parents=True, exist_ok=True)
        archive = download_dir / f"{asset['name']}.zip.part"
        expected_size = int(asset["size"])
        existing_size = archive.stat().st_size if archive.exists() else 0
        if existing_size > expected_size:
            archive.write_bytes(b"")
            existing_size = 0
        if existing_size == expected_size:
            return archive

        headers = {"User-Agent": "Hanabi-ED2K-Plugin/0.1.0"}
        if existing_size:
            headers["Range"] = f"bytes={existing_size}-"
        request = urllib.request.Request(str(asset["url"]), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                response_status = getattr(response, "status", response.getcode())
                append = existing_size > 0 and response_status == 206
                mode = "ab" if append else "wb"
                total = existing_size if append else 0
                with archive.open(mode) as output:
                    while True:
                        chunk = response.read(128 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > MAX_ENGINE_ARCHIVE_BYTES:
                            raise PluginFailure(
                                -32020, "aMule engine archive exceeded the size limit"
                            )
                        output.write(chunk)
        except PluginFailure:
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise PluginFailure(
                -32020,
                f"aMule engine download was interrupted and can be resumed: {error}",
            ) from error
        actual_size = archive.stat().st_size
        if actual_size != expected_size:
            raise PluginFailure(
                -32020,
                "aMule engine download is incomplete; retry to resume",
                {"downloaded": actual_size, "expected": expected_size},
            )
        return archive

    @staticmethod
    def _engine_asset() -> Mapping[str, Any] | None:
        if os.name != "nt":
            return None
        machine = platform.machine().strip().lower()
        if machine in {"amd64", "x86_64"}:
            return ENGINE_ASSETS["win-x64"]
        if machine in {"arm64", "aarch64"}:
            return ENGINE_ASSETS["win-arm64"]
        return None

    def _start_managed(
        self,
        engine: EnginePaths,
        config: Mapping[str, Any],
        previous_state: Mapping[str, Any],
    ) -> BackendSession:
        password = str(previous_state.get("password") or secrets.token_hex(32))
        used_ports: set[int] = set()
        ec_port = _usable_tcp_port(previous_state.get("ecPort"), used_ports)
        # 没有配置时端口是随机分配的，用户没法在路由器上做固定转发，也就
        # 永远拿不到 HighID。配置了就优先用它，UDP 沿用 eMule 的 TCP+10 惯例。
        configured_port = _bounded_int(config.get("listenPort"), 0, 0, 65535)
        client_port = _usable_tcp_port(
            configured_port or previous_state.get("clientPort"), used_ports
        )
        udp_port = _usable_udp_port(
            (configured_port + 10) if configured_port else previous_state.get("udpPort"),
            used_ports,
        )
        core_dir = self.data_dir / "core"
        incoming_dir = self.data_dir / "incoming"
        temporary_dir = self.data_dir / "temporary"
        for directory in (core_dir, incoming_dir, temporary_dir):
            directory.mkdir(parents=True, exist_ok=True)
        self._bootstrap_network_files(core_dir, config)
        self._write_amule_config(
            core_dir / "amule.conf",
            password=password,
            ec_port=ec_port,
            client_port=client_port,
            udp_port=udp_port,
            core_dir=core_dir,
            incoming_dir=incoming_dir,
            temporary_dir=temporary_dir,
            auto_connect=self._bool_setting(
                "AMULE_AUTO_CONNECT", config, "autoConnect", True
            ),
            upnp=self._bool_setting("AMULE_UPNP", config, "enableUpnp", True),
            max_sources=_bounded_int(config.get("maxSourcesPerFile"), 1000, 20, 1000),
            max_connections=_bounded_int(config.get("maxConnections"), 750, 100, 4000),
        )

        creation_flags = 0
        popen_options: dict[str, Any] = {}
        if os.name == "nt":
            creation_flags = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
            creation_flags |= getattr(
                subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200
            )
        else:
            popen_options["start_new_session"] = True
        log_path = self.log_dir / "amule.log"
        try:
            with log_path.open("ab") as log_file:
                process = subprocess.Popen(
                    [
                        str(engine.amuled),
                        f"--config-dir={core_dir}",
                        "--log-stdout",
                    ],
                    cwd=str(engine.amuled.parent),
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=log_file,
                    creationflags=creation_flags,
                    **popen_options,
                )
        except OSError as error:
            raise PluginFailure(-32020, f"Failed to start amuled: {error}") from error

        client = AmuleClient(engine.amulecmd, "127.0.0.1", ec_port, password, timeout=3)
        startup_seconds = _bounded_int(config.get("startupTimeoutSeconds"), 20, 3, 60)
        deadline = time.monotonic() + startup_seconds
        last_error = "daemon did not become ready"
        while time.monotonic() < deadline:
            if process.poll() is not None:
                last_error = f"amuled exited with code {process.returncode}"
                break
            try:
                client.verify_connection()
                _write_json_atomic(
                    self.data_dir / "managed-runtime.json",
                    {
                        "amulecmd": str(engine.amulecmd),
                        "amuled": str(engine.amuled),
                        "password": password,
                        "ecPort": ec_port,
                        "clientPort": client_port,
                        "udpPort": udp_port,
                        "incomingDir": str(incoming_dir),
                        "pid": process.pid,
                        "startedAt": _utc_timestamp(),
                    },
                )
                # Autoconnect only fires once the daemon believes it has a
                # usable server list; asking explicitly makes a cold start join
                # ed2k and Kad right away instead of after the first retry.
                client.connect()
                return BackendSession(
                    client=client,
                    incoming_dir=incoming_dir,
                    managed=True,
                    state_dir=self.data_dir,
                )
            except PluginFailure as error:
                last_error = error.message
                self.sleep(0.25)
        if process.poll() is None:
            process.terminate()
        raise PluginFailure(-32020, f"amuled did not become ready: {last_error}")

    def _bootstrap_network_files(
        self, core_dir: Path, config: Mapping[str, Any]
    ) -> None:
        """Seed server.met and nodes.dat so a cold daemon can find sources.

        Every step is best effort: an offline host still starts the daemon and
        aMule keeps whatever lists it already has.
        """
        if not self._bool_setting(
            "AMULE_BOOTSTRAP_NETWORK", config, "bootstrapNetwork", True
        ):
            return

        marker = self.data_dir / "network-bootstrap.json"
        previous = _read_json(marker)
        now = int(time.time())
        last_attempt = _nonnegative_int(previous.get("attemptedAtEpoch"))
        if now - last_attempt < NETWORK_ASSET_RETRY_SECONDS:
            return

        server_urls = self._source_urls(
            config,
            environment_name="AMULE_SERVER_MET_URL",
            config_names=("serverMetUrls", "serverMetUrl"),
            defaults_flag="useDefaultServerLists",
            defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
            fallbacks=SERVER_MET_URLS,
        )
        nodes_urls = self._source_urls(
            config,
            environment_name="AMULE_KAD_NODES_URL",
            config_names=("kadNodesUrls", "kadNodesUrl"),
            defaults_flag="useDefaultKadNodes",
            defaults_environment="AMULE_DEFAULT_KAD_NODES",
            fallbacks=KAD_NODES_URLS,
        )
        results = {
            "attemptedAtEpoch": now,
            "serverMet": _fetch_network_asset(
                core_dir / "server.met", server_urls, _is_server_met
            ),
            "nodesDat": _fetch_network_asset(
                core_dir / "nodes.dat", nodes_urls, _is_nodes_dat
            ),
            "serverMetUrls": list(server_urls),
            "kadNodesUrls": list(nodes_urls),
        }
        _write_json_atomic(marker, results)

    # 宿主设置页声明的控件 ID -> config.json 的键与类型。
    # 白名单保证插件只写自己认识的键，宿主 UI 里多出来的控件不会污染配置。
    SETTINGS_SCHEMA: Mapping[str, str] = {
        "enableUpnp": "bool",
        "autoConnect": "bool",
        "bootstrapNetwork": "bool",
        "serverMetUrl": "text",
        "useDefaultServerLists": "bool",
        "kadNodesUrl": "text",
        "useDefaultKadNodes": "bool",
        "maxSourcesPerFile": "int",
        "listenPort": "port",
    }

    def apply_settings(self, settings: Mapping[str, Any]) -> dict[str, Any]:
        """Merge host settings into config.json.

        Merged rather than replaced: the settings dialog only knows about the
        keys it declares, while the list manager and hand-written configs own
        the rest.
        """
        config = self._load_config()
        applied: dict[str, Any] = {}
        for key, kind in self.SETTINGS_SCHEMA.items():
            if key not in settings:
                continue
            raw = settings[key]
            if kind == "bool":
                value: Any = _coerce_bool(raw)
            elif kind == "int":
                value = _bounded_int(raw, 1000, 20, 1000)
            elif kind == "port":
                # 0 表示继续自动分配；1024 以下需要管理员权限，不接受。
                text = str(raw or "").strip()
                value = _bounded_int(text, 0, 0, 65535) if text else 0
                if value != 0 and value < 1024:
                    value = 0
            else:
                value = str(raw or "").strip()
            if value is None:
                continue
            config[key] = value
            applied[key] = value

        self.data_dir.mkdir(parents=True, exist_ok=True)
        _write_json_atomic(self.data_dir / "config.json", config)
        return {
            "applied": applied,
            # amuled 只在启动时读取配置，这里如实说明生效时机。
            "restartRequired": bool(applied),
        }

    def refresh_network_lists(self) -> dict[str, Any]:
        """Re-download server.met / nodes.dat regardless of their age."""
        config = self._load_config()
        core_dir = self.data_dir / "core"
        core_dir.mkdir(parents=True, exist_ok=True)
        server_urls = self._source_urls(
            config,
            environment_name="AMULE_SERVER_MET_URL",
            config_names=("serverMetUrls", "serverMetUrl"),
            defaults_flag="useDefaultServerLists",
            defaults_environment="AMULE_DEFAULT_SERVER_LISTS",
            fallbacks=SERVER_MET_URLS,
        )
        nodes_urls = self._source_urls(
            config,
            environment_name="AMULE_KAD_NODES_URL",
            config_names=("kadNodesUrls", "kadNodesUrl"),
            defaults_flag="useDefaultKadNodes",
            defaults_environment="AMULE_DEFAULT_KAD_NODES",
            fallbacks=KAD_NODES_URLS,
        )
        server_result = _fetch_network_asset(
            core_dir / "server.met", server_urls, _is_server_met, force=True
        )
        nodes_result = _fetch_network_asset(
            core_dir / "nodes.dat", nodes_urls, _is_nodes_dat, force=True
        )
        _write_json_atomic(
            self.data_dir / "network-bootstrap.json",
            {
                "attemptedAtEpoch": int(time.time()),
                "serverMet": server_result,
                "nodesDat": nodes_result,
                "serverMetUrls": list(server_urls),
                "kadNodesUrls": list(nodes_urls),
            },
        )
        return {
            "serverMet": server_result,
            "nodesDat": nodes_result,
            "restartRequired": True,
        }

    def _source_urls(
        self,
        config: Mapping[str, Any],
        *,
        environment_name: str,
        config_names: tuple[str, ...],
        defaults_flag: str,
        defaults_environment: str,
        fallbacks: tuple[str, ...],
    ) -> tuple[str, ...]:
        """Resolve list sources: user entries first, built-ins as fallback.

        Accepts a single URL, a comma/whitespace separated string, or a list,
        so the host settings UI and a hand-written config.json agree.
        """
        configured: list[str] = []
        environment_value = self.environ.get(environment_name)
        if environment_value is not None:
            configured.extend(_split_urls(environment_value))
        else:
            for name in config_names:
                configured.extend(_split_urls(config.get(name)))
        if self._bool_setting(defaults_environment, config, defaults_flag, True):
            configured.extend(fallbacks)

        ordered: list[str] = []
        seen: set[str] = set()
        for url in configured:
            if url and url not in seen:
                seen.add(url)
                ordered.append(url)
        return tuple(ordered)

    @staticmethod
    def _write_amule_config(
        path: Path,
        *,
        password: str,
        ec_port: int,
        client_port: int,
        udp_port: int,
        core_dir: Path,
        incoming_dir: Path,
        temporary_dir: Path,
        auto_connect: bool,
        upnp: bool = True,
        max_sources: int = 1000,
        max_connections: int = 750,
    ) -> None:
        parser = configparser.RawConfigParser(interpolation=None, strict=False)
        parser.optionxform = str
        if path.exists():
            parser.read(path, encoding="utf-8-sig")
        for section in ("eMule", "ExternalConnect", "WebServer", "Obfuscation"):
            if not parser.has_section(section):
                parser.add_section(section)
        values = {
            "Nick": "Hanabi ED2K",
            "Port": str(client_port),
            "UDPPort": str(udp_port),
            "UDPEnable": "1",
            "Autoconnect": "1" if auto_connect else "0",
            "Reconnect": "1",
            "ConnectToKad": "1",
            "ConnectToED2K": "1",
            # Without a router mapping the client stays firewalled (LowID),
            # which cuts it off from every other firewalled peer.
            "UPnPEnabled": "1" if upnp else "0",
            "UPnPTCPPort": str(client_port),
            "TempDir": _amule_path(temporary_dir),
            "IncomingDir": _amule_path(incoming_dir),
            "OSDirectory": _amule_path(core_dir) + ("\\\\" if os.name == "nt" else "/"),
            "AddNewFilesPaused": "0",
            "Language": "en",
            "NewVersionCheck": "0",
            "KadNodesUrl": KAD_NODES_URLS[0],
            "Ed2kServersUrl": SERVER_MET_URLS[0],
            # Serverlist=1 is aMule's "update the server list at startup"; the
            # shipped default of 0 leaves a fresh profile with zero servers.
            "Serverlist": "1",
            "AddServerListFromServer": "1",
            "AddServerListFromClient": "1",
            "SafeServerConnect": "0",
            "AutoConnectStaticOnly": "0",
            "RemoveDeadServer": "1",
            "DeadServerRetry": "3",
            "MaxSourcesPerFile": str(max_sources),
            "MaxConnections": str(max_connections),
            "MaxConnectionsPerFiveSeconds": "40",
            "MaxUpload": "0",
            "MaxDownload": "0",
            "DropSlowSources": "0",
            "FileBufferSizePref": "64",
            "CreateSparseFiles": "1",
            "ICH": "1",
            "SmartIdCheck": "1",
            "IPFilterAutoLoad": "0",
        }
        for key, value in values.items():
            parser.set("eMule", key, value)
        external_values = {
            "AcceptExternalConnections": "1",
            "ECAddress": "127.0.0.1",
            "ECPort": str(ec_port),
            "ECPassword": hashlib.md5(password.encode("utf-8")).hexdigest(),
            "UPnPECEnabled": "0",
        }
        for key, value in external_values.items():
            parser.set("ExternalConnect", key, value)
        # Obfuscated connections are the only way into servers and clients that
        # refuse plain ed2k, and several large servers now do.
        for key, value in {
            "IsClientCryptLayerSupported": "1",
            "IsCryptLayerRequested": "1",
            "IsClientCryptLayerRequired": "0",
        }.items():
            parser.set("Obfuscation", key, value)
        parser.set("WebServer", "Enabled", "0")
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
        with temporary.open("w", encoding="utf-8", newline="\n") as output:
            parser.write(output, space_around_delimiters=False)
        temporary.replace(path)

    def _text_setting(
        self,
        environment_name: str,
        config: Mapping[str, Any],
        config_name: str,
    ) -> str:
        environment_value = self.environ.get(environment_name)
        if environment_value is not None:
            return environment_value.strip()
        value = config.get(config_name)
        return "" if value is None else str(value).strip()

    def _bool_setting(
        self,
        environment_name: str,
        config: Mapping[str, Any],
        config_name: str,
        fallback: bool,
    ) -> bool:
        value: Any = self.environ.get(environment_name)
        if value is None:
            value = config.get(config_name, fallback)
        if isinstance(value, bool):
            return value
        normalized = str(value).strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
        return fallback

    @contextmanager
    def _startup_lock(self) -> Iterator[None]:
        lock_path = self.data_dir / "startup.lock"
        deadline = time.monotonic() + 20
        descriptor: int | None = None
        while descriptor is None:
            try:
                descriptor = os.open(
                    lock_path,
                    os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                    0o600,
                )
                os.write(descriptor, str(os.getpid()).encode("ascii"))
            except FileExistsError:
                try:
                    if time.time() - lock_path.stat().st_mtime > 300:
                        lock_path.unlink(missing_ok=True)
                        continue
                except OSError:
                    pass
                if time.monotonic() >= deadline:
                    raise PluginFailure(-32020, "Timed out waiting for aMule startup lock")
                self.sleep(0.1)
        try:
            yield
        finally:
            os.close(descriptor)
            lock_path.unlink(missing_ok=True)


class Ed2kService:
    def __init__(
        self,
        backend_factory: Callable[[], BackendSession] | None = None,
        *,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._provider = None if backend_factory else AmuleBackendProvider()
        self._backend_factory = backend_factory or self._provider.session
        self._now = now

    def create(self, params: Mapping[str, Any], plugin_id: str = "") -> dict[str, Any]:
        intent = params.get("intent")
        if not isinstance(intent, Mapping):
            raise PluginFailure(-32010, "Download intent is required")
        intent_type = str(intent.get("type") or "").strip().lower()
        if intent_type not in {"ed2k", "edonkey"}:
            raise PluginFailure(-32010, f"Unsupported intent type: {intent_type or 'empty'}")
        value = str(
            intent.get("normalizedValue") or intent.get("rawValue") or ""
        ).strip()
        link = Ed2kLink.parse(value)
        save_dir = str(params.get("saveDir") or "").strip()
        session, queue = self._queue()
        data = _plugin_data(
            link.file_hash,
            link.file_name,
            link.size,
            save_dir,
            session.incoming_dir,
            created_at=int(self._now()),
        )
        completed_path = _completed_path(data, session.incoming_dir, move_file=True)
        task = queue.get(link.file_hash)
        if task is None and completed_path is None:
            session.client.run(f"Add {link.normalized}", require_success=True)
        start_paused = bool(params.get("startPaused"))
        if start_paused and completed_path is None:
            session.client.run(f"Pause {link.file_hash}", require_success=True)
        status = "completed" if completed_path is not None else (
            "paused" if start_paused else _map_amule_state(task.state if task else "waiting", 0)
        )
        result = {
            "accepted": True,
            "taskId": f"plugin:{plugin_id or PLUGIN_ID}:{link.file_hash}",
            "status": status,
            "fileName": link.file_name,
            "totalSize": link.size,
            "pluginData": data,
        }
        if completed_path is not None:
            result["filePath"] = str(completed_path)
        return result

    def status(self, params: Mapping[str, Any]) -> dict[str, Any]:
        data = _task_data(params)
        session, queue = self._queue()
        task = queue.get(data["ed2kHash"])
        if task is not None:
            progress = task.progress
            downloaded = round(data["totalSize"] * progress)
            status = _map_amule_state(task.state, progress)
            data["missingSinceEpoch"] = 0
            return {
                "status": status,
                "totalSize": data["totalSize"],
                "downloadedSize": downloaded,
                "speed": self._sample_speed(data, downloaded),
                "progress": progress,
                "filePath": _intended_path(data, session.incoming_dir),
                "error": _amule_error(task.state),
                "peerCount": task.active_sources,
                "seeders": task.total_sources,
                "statusDetail": self._status_detail(session, task, status),
                "pluginData": data,
            }

        completed = _completed_path(data, session.incoming_dir, move_file=True)
        if completed is not None:
            data["finalPath"] = str(completed)
            data["missingSinceEpoch"] = 0
            return {
                "status": "completed",
                "totalSize": data["totalSize"],
                "downloadedSize": data["totalSize"],
                "speed": 0,
                "progress": 1.0,
                "filePath": str(completed),
                "error": "",
                "pluginData": data,
            }

        now = int(self._now())
        missing_since = _nonnegative_int(data.get("missingSinceEpoch"))
        if missing_since <= 0:
            missing_since = now
        data["missingSinceEpoch"] = missing_since
        within_grace = now - missing_since < MISSING_TASK_GRACE_SECONDS
        return {
            "status": "pending" if within_grace else "failed",
            "totalSize": data["totalSize"],
            "downloadedSize": 0,
            "speed": 0,
            "progress": 0.0,
            "filePath": _intended_path(data, session.incoming_dir),
            "error": "" if within_grace else "The aMule task is no longer in the download queue",
            "pluginData": data,
        }

    def pause(self, params: Mapping[str, Any]) -> dict[str, Any]:
        data = _task_data(params)
        session, queue = self._queue()
        task = queue.get(data["ed2kHash"])
        if task is None:
            return self.status(params)
        if task.state.strip().lower() != "paused":
            session.client.run(f"Pause {data['ed2kHash']}", require_success=True)
        return {"status": "paused", "pluginData": data}

    def resume(self, params: Mapping[str, Any]) -> dict[str, Any]:
        data = _task_data(params)
        session, queue = self._queue()
        task = queue.get(data["ed2kHash"])
        if task is None:
            return self.status(params)
        if task.state.strip().lower() == "paused":
            session.client.run(f"Resume {data['ed2kHash']}", require_success=True)
        return {"status": "pending", "pluginData": data}

    def remove(self, params: Mapping[str, Any]) -> dict[str, Any]:
        data = _task_data(params)
        session, queue = self._queue()
        if data["ed2kHash"] in queue:
            session.client.run(f"Cancel {data['ed2kHash']}", require_success=True)
        return {"status": "removed", "pluginData": data}

    def apply_settings(self, settings: Mapping[str, Any]) -> dict[str, Any]:
        return self._require_provider().apply_settings(settings)

    def refresh_network_lists(self) -> dict[str, Any]:
        result = self._require_provider().refresh_network_lists()
        # 新列表要等 amuled 重启才会载入，但让运行中的守护进程重新连一次
        # 服务器仍然有意义：之前连上的那台可能已经满员。
        try:
            session = self._backend_factory()
            session.client.connect()
        except PluginFailure:
            pass
        return result

    def _require_provider(self) -> AmuleBackendProvider:
        if self._provider is None:
            raise PluginFailure(
                -32020, "Settings are only available with the managed backend"
            )
        return self._provider

    def _queue(self) -> tuple[BackendSession, dict[str, AmuleTask]]:
        """Read the download queue, restarting a dead daemon once.

        The session fast path only probes the external-connection port, so a
        daemon that died and left the port to someone else is detected here.
        A timeout is not treated as death: restarting a busy daemon would drop
        every running transfer.
        """
        session = self._backend_factory()
        try:
            return session, session.client.show_downloads()
        except PluginFailure as error:
            if (
                self._provider is None
                or error.code != -32020
                or "Cannot connect" not in error.message
            ):
                raise
            self._provider.invalidate()
            session = self._backend_factory()
            return session, session.client.show_downloads()

    def _sample_speed(self, data: dict[str, Any], downloaded: int) -> int:
        """Derive a transfer rate from queue progress samples.

        aMule only reports whole tenths of a percent over external connections,
        so the byte count moves in bursts. The last rate is held between bursts
        and decays to zero once the task has clearly stalled.
        """
        now = int(self._now())
        previous_size = _nonnegative_int(data.get("lastSampleSize"))
        previous_at = _nonnegative_int(data.get("lastSampleEpoch"))
        previous_speed = _nonnegative_int(data.get("lastSpeed"))
        elapsed = now - previous_at

        if previous_at <= 0:
            data["lastSampleSize"] = downloaded
            data["lastSampleEpoch"] = now
            data["lastSpeed"] = 0
            return 0
        if downloaded > previous_size and elapsed > 0:
            speed = round((downloaded - previous_size) / elapsed)
            smoothed = (
                speed if previous_speed <= 0 else round(speed * 0.6 + previous_speed * 0.4)
            )
            data["lastSampleSize"] = downloaded
            data["lastSampleEpoch"] = now
            data["lastSpeed"] = smoothed
            return smoothed
        if downloaded < previous_size:
            data["lastSampleSize"] = downloaded
            data["lastSampleEpoch"] = now
            data["lastSpeed"] = 0
            return 0
        if elapsed >= STALLED_SAMPLE_SECONDS:
            data["lastSampleEpoch"] = now
            data["lastSpeed"] = 0
            return 0
        return previous_speed

    def _status_detail(
        self,
        session: BackendSession,
        task: AmuleTask,
        status: str,
    ) -> str:
        if status == "downloading":
            return f"{task.active_sources}/{task.total_sources} sources"

        network = self._network_state(session)
        parts: list[str] = []
        if task.total_sources > 0:
            parts.append(f"queued at {task.total_sources} sources")
        else:
            parts.append("searching for sources")
        if network is not None and network.recognized:
            if network.offline:
                parts.append("not connected to ed2k or Kad")
            elif not network.ed2k_connected:
                parts.append("Kad only, no ed2k server")
            elif network.firewalled:
                parts.append("firewalled (LowID)")
        return " · ".join(parts)

    def _network_state(self, session: BackendSession) -> NetworkState | None:
        """Probe ed2k/Kad connectivity at most once per interval, shared by all
        tasks, and nudge a disconnected daemon back onto the networks."""
        if session.state_dir is None:
            return None
        path = session.state_dir / "network-state.json"
        cached = _read_json(path)
        now = int(self._now())
        checked_at = _nonnegative_int(cached.get("checkedAtEpoch"))
        if now - checked_at < NETWORK_PROBE_INTERVAL_SECONDS and checked_at > 0:
            return NetworkState(
                ed2k_connected=bool(cached.get("ed2kConnected")),
                kad_connected=bool(cached.get("kadConnected")),
                firewalled=bool(cached.get("firewalled")),
                summary=str(cached.get("summary") or ""),
                recognized=bool(cached.get("recognized")),
            )

        try:
            state = session.client.connection_state()
        except PluginFailure:
            return None

        connected_at = _nonnegative_int(cached.get("connectRequestedAtEpoch"))
        if state.offline and now - connected_at >= RECONNECT_INTERVAL_SECONDS:
            session.client.connect()
            connected_at = now
        _write_json_atomic(
            path,
            {
                "checkedAtEpoch": now,
                "ed2kConnected": state.ed2k_connected,
                "kadConnected": state.kad_connected,
                "firewalled": state.firewalled,
                "summary": state.summary,
                "recognized": state.recognized,
                "connectRequestedAtEpoch": connected_at,
            },
        )
        return state


def _task_data(params: Mapping[str, Any]) -> dict[str, Any]:
    raw = params.get("pluginData")
    data = dict(raw) if isinstance(raw, Mapping) else {}
    task_id = str(params.get("taskId") or "")
    file_hash = str(data.get("ed2kHash") or task_id.rsplit(":", 1)[-1]).upper()
    if HASH_PATTERN.fullmatch(file_hash) is None:
        raise PluginFailure(-32010, "Task does not contain a valid ED2K hash")
    data["backend"] = "amule"
    data["schemaVersion"] = 1
    data["ed2kHash"] = file_hash
    data["fileName"] = _safe_file_name(
        str(data.get("fileName") or params.get("fileName") or file_hash)
    )
    data["totalSize"] = _nonnegative_int(data.get("totalSize"))
    if data["totalSize"] <= 0:
        raise PluginFailure(-32010, "Task does not contain a valid ED2K file size")
    data["saveDir"] = str(data.get("saveDir") or params.get("saveDir") or "")
    return data


def _plugin_data(
    file_hash: str,
    file_name: str,
    total_size: int,
    save_dir: str,
    incoming_dir: Path | None,
    *,
    created_at: int,
) -> dict[str, Any]:
    return {
        "backend": "amule",
        "schemaVersion": 1,
        "ed2kHash": file_hash,
        "fileName": file_name,
        "totalSize": total_size,
        "saveDir": save_dir,
        "incomingDir": str(incoming_dir) if incoming_dir is not None else "",
        "createdAtEpoch": created_at,
        "missingSinceEpoch": 0,
    }


def _completed_path(
    data: Mapping[str, Any],
    session_incoming: Path | None,
    *,
    move_file: bool,
) -> Path | None:
    total_size = _nonnegative_int(data.get("totalSize"))
    file_name = _safe_file_name(str(data.get("fileName") or "download"))
    final_path_value = str(data.get("finalPath") or "").strip()
    if final_path_value:
        final_path = Path(final_path_value)
        if _file_has_size(final_path, total_size):
            return final_path
    save_dir_value = str(data.get("saveDir") or "").strip()
    save_dir = Path(save_dir_value).expanduser() if save_dir_value else None
    incoming_value = str(data.get("incomingDir") or "").strip()
    incoming = Path(incoming_value) if incoming_value else session_incoming
    source = incoming / file_name if incoming is not None else None
    if source is None or not _file_has_size(source, total_size):
        return None
    if save_dir is None or not move_file:
        return source
    save_dir.mkdir(parents=True, exist_ok=True)
    destination = save_dir / file_name
    if destination.exists() and source.resolve() != destination.resolve():
        destination = _unique_destination(destination, str(data.get("ed2kHash") or "")[:8])
    if source.resolve() != destination.resolve():
        shutil.move(str(source), str(destination))
    return destination


def _intended_path(data: Mapping[str, Any], session_incoming: Path | None) -> str:
    final_path = str(data.get("finalPath") or "").strip()
    if final_path:
        return final_path
    file_name = _safe_file_name(str(data.get("fileName") or "download"))
    save_dir = str(data.get("saveDir") or "").strip()
    if save_dir:
        return str(Path(save_dir).expanduser() / file_name)
    incoming = str(data.get("incomingDir") or "").strip()
    if incoming:
        return str(Path(incoming) / file_name)
    return str(session_incoming / file_name) if session_incoming is not None else ""


def _map_amule_state(state: str, progress: float) -> str:
    normalized = state.strip().lower()
    if progress >= 1:
        return "verifying"
    if "pause" in normalized:
        return "paused"
    if any(value in normalized for value in ("download", "hashing")):
        return "downloading" if "download" in normalized else "verifying"
    if any(value in normalized for value in ("error", "insufficient", "erroneous")):
        return "failed"
    return "pending"


def _amule_error(state: str) -> str:
    normalized = state.strip().lower()
    if any(value in normalized for value in ("error", "insufficient", "erroneous")):
        return state.strip()
    return ""


def _safe_file_name(value: str) -> str:
    decoded = value.strip()
    sanitized = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", decoded).strip(" .")
    if sanitized in {"", ".", ".."}:
        raise PluginFailure(-32010, "ED2K file name is empty or unsafe")
    return sanitized[:240]


def _file_has_size(path: Path, expected_size: int) -> bool:
    try:
        return path.is_file() and path.stat().st_size == expected_size
    except OSError:
        return False


def _unique_destination(path: Path, suffix: str) -> Path:
    suffix = suffix or secrets.token_hex(4)
    candidate = path.with_name(f"{path.stem} ({suffix}){path.suffix}")
    counter = 2
    while candidate.exists():
        candidate = path.with_name(f"{path.stem} ({suffix}-{counter}){path.suffix}")
        counter += 1
    return candidate


def _engine_pair(directory: Path) -> EnginePaths | None:
    daemon_name = "amuled.exe" if os.name == "nt" else "amuled"
    command_name = "amulecmd.exe" if os.name == "nt" else "amulecmd"
    roots = [directory, directory / "bin"]
    for root in roots:
        daemon = root / daemon_name
        command = root / command_name
        if daemon.is_file() and command.is_file():
            return EnginePaths(daemon.resolve(), command.resolve())
    return None


def _decode_process_output(stdout: bytes, stderr: bytes) -> str:
    payload = stdout + (b"\n" if stdout and stderr else b"") + stderr
    encodings = ["utf-8", locale.getpreferredencoding(False), "cp1252"]
    for encoding in dict.fromkeys(encodings):
        try:
            return payload.decode(encoding)
        except (UnicodeDecodeError, LookupError):
            continue
    return payload.decode("utf-8", errors="replace")


def _last_output_line(output: str) -> str:
    lines = [line.strip(" >\t\r") for line in output.splitlines() if line.strip()]
    return lines[-1] if lines else "no output"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _usable_tcp_port(value: Any, used: set[int]) -> int:
    candidate = _bounded_int(value, 0, 0, 65535)
    if candidate > 0 and candidate not in used and _tcp_port_available(candidate):
        used.add(candidate)
        return candidate
    while True:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            selected = int(listener.getsockname()[1])
        if selected not in used:
            used.add(selected)
            return selected


def _usable_udp_port(value: Any, used: set[int]) -> int:
    candidate = _bounded_int(value, 0, 0, 65535)
    if candidate > 0 and candidate not in used and _udp_port_available(candidate):
        used.add(candidate)
        return candidate
    while True:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
            listener.bind(("127.0.0.1", 0))
            selected = int(listener.getsockname()[1])
        if selected not in used:
            used.add(selected)
            return selected


def _tcp_port_available(port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False


def _udp_port_available(port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
            listener.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False


def _bounded_int(value: Any, fallback: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return fallback
    return max(minimum, min(parsed, maximum))


def _nonnegative_int(value: Any) -> int:
    return _bounded_int(value, 0, 0, 2**63 - 1)


def _amule_path(path: Path) -> str:
    value = str(path.resolve())
    return value.replace("\\", "\\\\") if os.name == "nt" else value


def _read_json(path: Path) -> dict[str, Any]:
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _split_urls(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        items = [str(item) for item in value]
    else:
        # Commas appear inside query strings (dl.php?load=min), so only split
        # on newlines and whitespace unless a comma separates two schemes.
        items = re.split(r"[\s\r\n]+|,(?=\s*[a-zA-Z][a-zA-Z0-9+.-]*://)", str(value))
    return [item.strip() for item in items if item and item.strip()]


def _ec_port_responding(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def _is_server_met(payload: bytes) -> bool:
    # server.met starts with a version byte (0xE0 for the current format)
    # followed by a little-endian server count. An HTML error page or a
    # rate-limit notice must never be written over the real list.
    if payload[0] not in (0xE0, 0x0E):
        return False
    count = int.from_bytes(payload[1:5], "little")
    return 0 < count <= 100000


def _is_nodes_dat(payload: bytes) -> bool:
    if payload[:1] in (b"<", b"{", b"#"):
        return False
    # Legacy layout is a contact count; the current one is a zero marker
    # followed by a version. Both start with a small little-endian integer.
    head = int.from_bytes(payload[0:4], "little")
    return head <= 100000


def _coerce_bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return None


def _fetch_network_asset(
    destination: Path,
    urls: tuple[str, ...],
    validate: Callable[[bytes], bool] | None = None,
    *,
    force: bool = False,
) -> str:
    """Download server.met / nodes.dat when missing or stale.

    Returns a short outcome string for the bootstrap marker file. Failures are
    reported, never raised: a stale list still beats refusing to start.
    """
    try:
        if destination.is_file() and not force:
            stat = destination.stat()
            fresh = time.time() - stat.st_mtime < NETWORK_ASSET_MAX_AGE_SECONDS
            if fresh and stat.st_size >= MIN_NETWORK_ASSET_BYTES:
                return "kept"
    except OSError:
        pass

    last_error = "no url"
    for url in urls:
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "Hanabi-ED2K-Plugin/0.2.0"}
            )
            with urllib.request.urlopen(
                request, timeout=NETWORK_ASSET_TIMEOUT_SECONDS
            ) as response:
                payload = response.read(MAX_NETWORK_ASSET_BYTES + 1)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            last_error = str(error)
            continue
        if len(payload) < MIN_NETWORK_ASSET_BYTES:
            last_error = "response too small"
            continue
        if len(payload) > MAX_NETWORK_ASSET_BYTES:
            last_error = "response too large"
            continue
        if validate is not None and not validate(payload):
            last_error = f"unexpected content from {url}"
            continue
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(
                f".{destination.name}.tmp-{os.getpid()}-{secrets.token_hex(4)}"
            )
            temporary.write_bytes(payload)
            temporary.replace(destination)
        except OSError as error:
            last_error = str(error)
            continue
        return f"updated from {url}"
    return f"failed: {last_error}"


def _write_json_atomic(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}-{secrets.token_hex(4)}")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
