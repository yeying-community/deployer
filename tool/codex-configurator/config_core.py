"""Offline, conservative Codex configuration updates. No network or process control."""

from __future__ import annotations

import base64
import ctypes
from ctypes import wintypes
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
import tomllib
import uuid

import tomlkit

VERSION = "0.1.4"
BASE_URL = "https://router.yeying.pub/v1"
# Codex model IDs from https://learn.chatgpt.com/docs/models (2026-11-01).
BUILTIN_MODELS = (
    "gpt-6.1-sol",
    "gpt-6.1-terra",
    "gpt-6-astra",
    "gpt-6-luna",
    "gpt-6-sol",
)
MODEL = BUILTIN_MODELS[0]
PROVIDER = "yeying"
MAX_FILE = 4 * 1024 * 1024


class ConfigError(Exception):
    """User-readable errors deliberately exclude file contents and credentials."""


def digest(data: bytes | None) -> str | None:
    return None if data is None else hashlib.sha256(data).hexdigest()


def config_path() -> Path:
    configured = os.environ.get("CODEX_HOME", "").strip()
    if configured:
        home = Path(os.path.expandvars(configured)).expanduser()
        if not home.is_absolute():
            raise ConfigError("CODEX_HOME 不是绝对路径，请手动选择配置文件。")
    elif os.name == "nt":
        buffer = ctypes.create_unicode_buffer(32768)
        if ctypes.windll.shell32.SHGetFolderPathW(None, 0x28, None, 0, buffer) != 0:
            raise ConfigError("无法取得 Windows 用户目录，请手动选择配置文件。")
        home = Path(buffer.value) / ".codex"
    else:
        home = Path.home() / ".codex"
    return home.absolute() / "config.toml"


def read_file(path: Path, limit: int = MAX_FILE) -> bytes | None:
    if path.is_symlink():
        raise ConfigError("配置文件是符号链接，请选择链接实际指向的配置文件。")
    try:
        with path.open("rb") as stream:
            data = stream.read(limit + 1)
    except FileNotFoundError:
        return None
    except OSError:
        raise ConfigError("无法读取文件，请检查目录和访问权限。") from None
    if len(data) > limit:
        raise ConfigError("配置文件过大，本次未修改。")
    return data


def parse_config(data: bytes | None):
    try:
        text = (data or b"").decode("utf-8-sig")
        tomllib.loads(text)
        return tomlkit.parse(text)
    except (ValueError, UnicodeError):
        raise ConfigError("原配置不是有效的 UTF-8 TOML，本次未修改。请先在 Codex 设置中检查配置。") from None


def clean_key(value: str) -> str:
    key = value.strip()
    if not key:
        raise ConfigError("请先填写自己的夜莺 Router API Key。")
    if len(key) > 4096 or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in key):
        raise ConfigError("API Key 中包含空白或无效字符，请重新复制完整 Key。")
    return key


def clean_model(value: str) -> str:
    if not isinstance(value, str):
        raise ConfigError("请填写模型名称。")
    model = value.strip()
    if not model or len(model) > 256 or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in model):
        raise ConfigError("请填写完整模型名称，不要包含空白或换行。")
    return model


def configured_model(path: Path) -> str:
    doc = parse_config(read_file(path))
    model = doc.get("model", MODEL)
    active = doc.get("profile")
    profiles = doc.get("profiles", {})
    if isinstance(active, str) and hasattr(profiles, "get"):
        profile = profiles.get(active, {})
        if hasattr(profile, "get"):
            model = profile.get("model", model)
    return clean_model(model)


def merge_config(data: bytes | None, key: str, model: str = MODEL) -> bytes:
    key = clean_key(key)
    model = clean_model(model)
    doc = parse_config(data)
    if doc.get("forced_login_method") == "chatgpt":
        raise ConfigError("原配置强制使用 ChatGPT 账号登录，请先在 Codex 中取消该限制。")
    # TOMLKit puts new scalar keys before the first table, including [desktop].
    doc["model"] = model
    doc["model_provider"] = PROVIDER
    providers = doc.get("model_providers")
    if providers is None:
        providers = tomlkit.table()
        doc["model_providers"] = providers
    if not isinstance(providers, (dict, tomlkit.items.Table, tomlkit.items.InlineTable)):
        raise ConfigError("model_providers 结构异常，本次未修改。")
    provider = providers.get(PROVIDER)
    if provider is None:
        provider = tomlkit.table()
        providers[PROVIDER] = provider
    if not isinstance(provider, (dict, tomlkit.items.Table, tomlkit.items.InlineTable)):
        raise ConfigError("原夜莺提供商配置结构异常，本次未修改。")
    for field in ("env_key", "env_key_instructions", "auth", "gateway_oauth"):
        provider.pop(field, None)
    for field in ("http_headers", "env_http_headers"):
        headers = provider.get(field)
        if headers is not None:
            if not hasattr(headers, "keys"):
                raise ConfigError("原夜莺提供商请求头结构异常，本次未修改。")
            for header in list(headers):
                if str(header).lower() == "authorization":
                    del headers[header]
    for field, value in {
        "name": "Yeying Router", "base_url": BASE_URL, "wire_api": "responses",
        "experimental_bearer_token": key, "requires_openai_auth": False,
    }.items():
        provider[field] = value
    active = doc.get("profile")
    if active:
        profiles = doc.get("profiles", {})
        if not hasattr(profiles, "get"):
            raise ConfigError("原 profiles 结构异常，本次未修改。")
        profile = profiles.get(active)
        if profile is not None:
            if not hasattr(profile, "keys"):
                raise ConfigError("当前 profile 结构异常，本次未修改。")
            for field, value in (("model", model), ("model_provider", PROVIDER)):
                if field in profile:
                    profile[field] = value
    result = tomlkit.dumps(doc).encode("utf-8")
    if data and data.startswith(b"\xef\xbb\xbf"):
        result = b"\xef\xbb\xbf" + result
    parsed = tomllib.loads(result.decode("utf-8-sig"))
    if parsed.get("model_provider") != PROVIDER or parsed.get("model") != model:
        raise ConfigError("配置校验未通过，本次未修改。")
    return result


class DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _dpapi(data: bytes, decrypt: bool) -> bytes:
    if os.name != "nt":
        raise ConfigError("此版本的加密备份仅支持 Windows。")
    buffer = ctypes.create_string_buffer(data, len(data))
    source = DataBlob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = DataBlob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    if decrypt:
        ok = crypt.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        ok = crypt.CryptProtectData(ctypes.byref(source), "Yeying Codex Backup", None, None, None, 1, ctypes.byref(target))
    if not ok:
        raise ConfigError("无法处理 Windows 加密备份，请使用创建备份的 Windows 账号。")
    try:
        return ctypes.string_at(target.pbData, target.cbData)
    finally:
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree(ctypes.cast(target.pbData, ctypes.c_void_p))


def protect(data: bytes) -> bytes:
    return _dpapi(data, False)


def unprotect(data: bytes) -> bytes:
    return _dpapi(data, True)


def atomic_write(path: Path, data: bytes | None, expected: bytes | None):
    if read_file(path) != expected:
        raise ConfigError("文件刚被其他程序修改，本次已取消。请重新检查后再试。")
    if data is None:
        if expected is not None:
            path.unlink()
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        fd, temp_name = tempfile.mkstemp(prefix=".yeying-", suffix=".tmp", dir=path.parent)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # A second comparison after the slower write narrows the concurrency window.
        if read_file(path) != expected:
            raise ConfigError("文件刚被其他程序修改，本次已取消。请重新检查后再试。")
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name is not None:
            Path(temp_name).unlink(missing_ok=True)


@dataclass(frozen=True)
class Plan:
    path: Path
    before: dict[str, bytes | None]
    after: dict[str, bytes | None]
    profile_guard: tuple[Path, bytes | None] | None
    notices: tuple[str, ...]


def prepare(path: Path, key: str, model: str = MODEL) -> Plan:
    path = path.absolute()
    if path.name.lower() != "config.toml":
        raise ConfigError("请选择名为 config.toml 的文件。")
    before = {"config.toml": read_file(path)}
    after = {"config.toml": merge_config(before["config.toml"], key, model)}
    parsed = parse_config(before["config.toml"])
    notices = []
    guard = None
    active = parsed.get("profile")
    if active:
        if not isinstance(active, str) or any(c in active for c in "/\\:") or active in (".", ".."):
            raise ConfigError("当前 profile 名称异常，本次未修改。")
        external = path.parent / f"{active}.config.toml"
        raw = read_file(external)
        guard = (external, raw)
        profile = parse_config(raw)
        if any(field in profile for field in ("model", "model_provider", "model_providers")):
            raise ConfigError("当前独立 profile 文件会覆盖模型配置，请先在 Codex 中取消该 profile 后再配置。")
    auth = read_file(path.parent / "auth.json")
    store = parsed.get("cli_auth_credentials_store", "file")
    if auth is None and store not in ("keyring", "ephemeral"):
        # Seed only a missing API login file. Existing accounts are never replaced.
        before["auth.json"] = None
        after["auth.json"] = (json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": clean_key(key)}, indent=2) + "\n").encode()
        notices.append("已补齐首次使用的本地 API 登录文件。")
    elif auth is None:
        notices.append("当前使用独立凭据存储；如仍出现登录页，请选择 API Key 登录。")
    else:
        notices.append("保留已有登录状态。")
    return Plan(path, before, after, guard, tuple(notices))


def backup_root(path: Path) -> Path:
    return path.parent / ".yeying-configurator"


def _verify_plan(plan: Plan):
    for name, expected in plan.before.items():
        if read_file(plan.path.parent / name) != expected:
            raise ConfigError("文件刚被其他程序修改，本次已取消。请重新检查后再试。")
    if plan.profile_guard and read_file(plan.profile_guard[0]) != plan.profile_guard[1]:
        raise ConfigError("当前 profile 刚被修改，本次已取消。")


def _transaction(root: Path, before: dict, after: dict):
    written = []
    try:
        for name, payload in after.items():
            if payload == before[name]:
                continue
            atomic_write(root / name, payload, before[name])
            written.append(name)
            if read_file(root / name) != payload:
                raise ConfigError("写入后的文件校验失败。")
    except Exception as exc:
        recovered = True
        for name in reversed(written):
            try:
                atomic_write(root / name, before[name], after[name])
            except Exception:
                recovered = False
        if not recovered:
            raise ConfigError("保存中断，且文件又被其他程序修改；请保留备份并检查文件。") from None
        if isinstance(exc, ConfigError):
            raise
        raise ConfigError("保存失败，原配置已保留。请检查文件权限、只读属性或磁盘空间。") from None


def apply(plan: Plan) -> bool:
    """Save a DPAPI recovery capsule before replacing either file."""
    _verify_plan(plan)
    if plan.before == plan.after:
        return False
    capsule = {
        "version": 1, "path": str(plan.path),
        "before": {n: None if v is None else base64.b64encode(v).decode() for n, v in plan.before.items()},
        "after": {n: digest(v) for n, v in plan.after.items()},
    }
    folder = backup_root(plan.path)
    folder.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = folder / f"{stamp}-{uuid.uuid4().hex[:8]}.dpapi"
    marker = folder / "latest.json"
    try:
        atomic_write(backup, protect(json.dumps(capsule).encode()), None)
        previous_marker = read_file(marker)
        _verify_plan(plan)
        _transaction(plan.path.parent, plan.before, plan.after)
        try:
            payload = json.dumps({"backup": backup.name, "version": 1}).encode()
            atomic_write(marker, payload, previous_marker)
        except Exception:
            _transaction(plan.path.parent, plan.after, plan.before)
            raise ConfigError("无法登记恢复点，已撤销本次配置。") from None
    except OSError:
        raise ConfigError("无法创建备份，本次未修改。请检查目录权限和磁盘空间。") from None
    return True


def can_restore(path: Path) -> bool:
    return (backup_root(path) / "latest.json").is_file()


def restore(path: Path):
    path = path.absolute()
    folder = backup_root(path)
    marker = folder / "latest.json"
    raw_marker = read_file(marker)
    if raw_marker is None:
        raise ConfigError("没有可恢复的配置备份。")
    try:
        name = json.loads(raw_marker)["backup"]
        if not isinstance(name, str) or Path(name).name != name or not name.endswith(".dpapi"):
            raise ValueError()
        encrypted = read_file(folder / name, MAX_FILE * 2)
        if encrypted is None:
            raise ValueError()
        capsule = json.loads(unprotect(encrypted))
        if capsule["version"] != 1 or capsule["path"] != str(path):
            raise ValueError()
        names = set(capsule["before"])
        if names != set(capsule["after"]) or not names or not names <= {"config.toml", "auth.json"}:
            raise ValueError()
        previous = {n: None if v is None else base64.b64decode(v, validate=True) for n, v in capsule["before"].items()}
        current = {n: read_file(path.parent / n) for n in names}
    except ConfigError:
        raise
    except (ValueError, KeyError, TypeError):
        raise ConfigError("备份格式异常，本次未恢复。") from None
    for n in names:
        if digest(current[n]) != capsule["after"][n]:
            raise ConfigError("配置在保存后又被修改，为保留后续设置，本次未恢复。")
    _transaction(path.parent, current, previous)
    try:
        atomic_write(marker, None, raw_marker)
    except Exception:
        _transaction(path.parent, previous, current)
        raise ConfigError("恢复点状态发生变化，已撤销本次恢复。") from None
