#!/usr/bin/env python3
"""Collect and analyze daily ERROR log groups with the Codex CLI.

The orchestrator is intentionally deterministic: it filters and redacts logs,
persists fingerprints, enforces a daily budget, and only records a successful
analysis after validating the Codex JSON response.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = SCRIPT_DIR / "analyzer.conf"
DEFAULT_PROMPT = SCRIPT_DIR / "prompt.txt"
DEFAULT_SCHEMA = SCRIPT_DIR / "root-cause.schema.json"

TIMESTAMP_PATTERNS = (
    re.compile(r"\b\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"),
    re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"),
)
SECRET_PATTERNS = (
    re.compile(r"(?i)\b(authorization\s*:\s*bearer|bearer|token|api[_-]?key|access[_-]?key|secret[_-]?key|cookie|password)\s*[:=]\s*\S+"),
    re.compile(r"(?i)\b(sk-[a-z0-9_-]+|ak-[a-z0-9_-]+)\b"),
)
ID_PATTERNS = (
    re.compile(r"(?i)\b(?:request|trace|correlation)[_-]?id\s*[:=]\s*[\w.-]+"),
    re.compile(r"\b[0-9a-f]{8}-[0-9a-f-]{27,}\b"),
    re.compile(r"\b0x[0-9a-f]+\b"),
)
NUMBER_PATTERN = re.compile(r"\b\d+\b")
SPACE_PATTERN = re.compile(r"\s+")
ERROR_PATTERN = re.compile(r"(?i)\b(?:error|fatal|panic|exception|traceback)\b")
DATE_PATTERN = re.compile(r"(?P<year>\d{4})[-/](?P<month>\d{2})[-/](?P<day>\d{2})")


@dataclass(frozen=True)
class ErrorGroup:
    module: str
    fingerprint: str
    normalized: str
    samples: tuple[str, ...]
    occurrences: int
    first_seen: str
    last_seen: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--date", help="analysis date in YYYY-MM-DD; defaults to local date")
    parser.add_argument("--module", action="append", help="restrict analysis to one or more modules")
    parser.add_argument("--dry-run", action="store_true", help="collect groups without invoking Codex")
    return parser.parse_args()


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise RuntimeError(f"config file does not exist: {path}")
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid JSON config: {path}: {exc}") from exc
    if not isinstance(config, dict):
        raise RuntimeError("config root must be an object")
    return config


def config_path(config: dict[str, Any], key: str, default: Path) -> Path:
    value = config.get(key)
    return Path(value).expanduser() if value else default


def get_timezone(config: dict[str, Any]) -> ZoneInfo:
    try:
        return ZoneInfo(str(config.get("timezone", "Asia/Shanghai")))
    except Exception as exc:
        raise RuntimeError(f"invalid timezone: {config.get('timezone')}") from exc


def local_date(config: dict[str, Any], date_arg: str | None) -> dt.date:
    if date_arg:
        try:
            return dt.date.fromisoformat(date_arg)
        except ValueError as exc:
            raise RuntimeError(f"invalid --date: {date_arg}") from exc
    return dt.datetime.now(get_timezone(config)).date()


def discover_deploy_dir(deploy_root: Path, module: str) -> Path | None:
    active = deploy_root / module
    if active.is_symlink() or active.is_dir():
        resolved = active.resolve()
        if resolved.is_dir():
            return resolved
    candidates = []
    for candidate in deploy_root.glob(f"{module}-*"):
        if candidate.is_dir():
            match = re.match(rf"^{re.escape(module)}-v?(\d+(?:\.\d+)*)-([0-9a-f]+)$", candidate.name)
            if match:
                version = tuple(int(part) for part in match.group(1).split("."))
                candidates.append((version, candidate.name, candidate))
    return max(candidates, key=lambda item: (item[0], item[1]))[2] if candidates else None


def iter_modules(config: dict[str, Any], requested: list[str] | None) -> list[str]:
    if requested:
        return requested
    modules_file = config_path(config, "modules_file", SCRIPT_DIR / "modules.conf")
    if not modules_file.exists():
        raise RuntimeError(f"modules file does not exist: {modules_file}")
    modules = []
    for line in modules_file.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if value and not value.startswith("#"):
            modules.append(value)
    return modules


def redact(text: str) -> str:
    result = text
    for pattern in SECRET_PATTERNS:
        result = pattern.sub(lambda match: f"{match.group(1) if match.lastindex else 'secret'}=[REDACTED]", result)
    for pattern in ID_PATTERNS:
        result = pattern.sub("[ID_REDACTED]", result)
    return result


def normalize_error(text: str) -> str:
    result = redact(text.strip())
    for pattern in TIMESTAMP_PATTERNS:
        result = pattern.sub("[TIME]", result)
    result = re.sub(r"(?i)(?:/[^ ]+)+(?:\.[A-Za-z0-9_-]+)?", "[PATH]", result)
    result = NUMBER_PATTERN.sub("[N]", result)
    result = SPACE_PATTERN.sub(" ", result).strip().lower()
    return result


def extract_date(text: str) -> dt.date | None:
    match = DATE_PATTERN.search(text)
    if not match:
        return None
    try:
        return dt.date(int(match.group("year")), int(match.group("month")), int(match.group("day")))
    except ValueError:
        return None


def extract_timestamp(text: str, fallback: dt.datetime) -> dt.datetime:
    match = re.search(
        r"(?P<date>\d{4}[-/]\d{2}[-/]\d{2})[ T-]+(?P<time>\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)",
        text,
    )
    if not match:
        return fallback
    value = match.group("time").replace(",", ".")
    try:
        parsed = dt.datetime.fromisoformat(f"{match.group('date').replace('/', '-') } {value}")
        return parsed.replace(tzinfo=fallback.tzinfo)
    except ValueError:
        return fallback


def read_error_groups(
    module: str,
    error_log: Path,
    target_date: dt.date,
    timezone: ZoneInfo,
    samples_per_group: int,
    sample_chars: int,
) -> list[ErrorGroup]:
    if not error_log.exists():
        return []
    groups: dict[str, dict[str, Any]] = {}
    fallback = dt.datetime.combine(target_date, dt.time.min, tzinfo=timezone)
    with error_log.open("r", encoding="utf-8", errors="replace") as stream:
        for raw_line in stream:
            if not ERROR_PATTERN.search(raw_line):
                continue
            line_date = extract_date(raw_line)
            if line_date is not None and line_date != target_date:
                continue
            cleaned = redact(raw_line.strip())
            if not cleaned:
                continue
            timestamp = extract_timestamp(cleaned, fallback)
            normalized = normalize_error(cleaned)
            if not normalized:
                continue
            item = groups.setdefault(
                normalized,
                {
                    "samples": [],
                    "occurrences": 0,
                    "first_seen": timestamp.isoformat(),
                    "last_seen": timestamp.isoformat(),
                },
            )
            item["occurrences"] += 1
            item["first_seen"] = min(item["first_seen"], timestamp.isoformat())
            item["last_seen"] = max(item["last_seen"], timestamp.isoformat())
            if len(item["samples"]) < samples_per_group and len(cleaned) <= sample_chars:
                item["samples"].append(cleaned)
            elif len(item["samples"]) < samples_per_group:
                item["samples"].append(cleaned[:sample_chars] + " ...[TRUNCATED]")
    result = []
    for normalized, item in groups.items():
        fingerprint = hashlib.sha256(f"{module}\0{normalized}".encode("utf-8")).hexdigest()
        result.append(
            ErrorGroup(
                module=module,
                fingerprint=fingerprint,
                normalized=normalized,
                samples=tuple(item["samples"]),
                occurrences=item["occurrences"],
                first_seen=item["first_seen"],
                last_seen=item["last_seen"],
            )
        )
    return sorted(result, key=lambda group: (-group.occurrences, group.fingerprint))


def open_database(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS error_groups (
            fingerprint TEXT PRIMARY KEY,
            module TEXT NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            occurrences INTEGER NOT NULL,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '',
            result_path TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        )
        """
    )
    connection.commit()
    return connection


def should_analyze(connection: sqlite3.Connection, group: ErrorGroup, retry_after: int) -> bool:
    row = connection.execute(
        "SELECT status, updated_at FROM error_groups WHERE fingerprint = ?", (group.fingerprint,)
    ).fetchone()
    if row is None:
        return True
    status, updated_at = row
    if status == "success":
        return False
    try:
        updated = dt.datetime.fromisoformat(updated_at)
        age = (dt.datetime.now(dt.timezone.utc) - updated).total_seconds()
        return age >= retry_after
    except ValueError:
        return True


def upsert_group(
    connection: sqlite3.Connection,
    group: ErrorGroup,
    status: str,
    result_path: str = "",
    last_error: str = "",
    increment_attempt: bool = False,
) -> None:
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    connection.execute(
        """
        INSERT INTO error_groups
            (fingerprint, module, first_seen, last_seen, occurrences, status, attempts,
             last_error, result_path, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(fingerprint) DO UPDATE SET
            module=excluded.module,
            first_seen=min(error_groups.first_seen, excluded.first_seen),
            last_seen=max(error_groups.last_seen, excluded.last_seen),
            occurrences=excluded.occurrences,
            status=excluded.status,
            attempts=error_groups.attempts + excluded.attempts,
            last_error=excluded.last_error,
            result_path=excluded.result_path,
            updated_at=excluded.updated_at
        """,
        (
            group.fingerprint,
            group.module,
            group.first_seen,
            group.last_seen,
            group.occurrences,
            status,
            1 if increment_attempt else 0,
            last_error,
            result_path,
            now,
        ),
    )


def load_prompt(path: Path, group: ErrorGroup) -> str:
    template = path.read_text(encoding="utf-8")
    case = {
        "module": group.module,
        "dedup_fingerprint": group.fingerprint,
        "occurrences": group.occurrences,
        "first_seen": group.first_seen,
        "last_seen": group.last_seen,
        "normalized_error": group.normalized,
        "samples": list(group.samples),
    }
    return template.rstrip() + "\n\nINPUT_CASE_JSON:\n" + json.dumps(case, ensure_ascii=False, indent=2) + "\n"


def validate_result(value: Any, group: ErrorGroup) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Codex result must be a JSON object")
    required = (
        "summary",
        "root_cause",
        "confidence",
        "evidence",
        "impact",
        "recommended_actions",
        "missing_information",
    )
    missing = [key for key in required if key not in value]
    if missing:
        raise ValueError(f"Codex result missing fields: {', '.join(missing)}")
    try:
        confidence = float(value["confidence"])
    except (TypeError, ValueError) as exc:
        raise ValueError("confidence must be numeric") from exc
    if not 0 <= confidence <= 1:
        raise ValueError("confidence must be between 0 and 1")
    result = dict(value)
    result["dedup_fingerprint"] = group.fingerprint
    result["occurrences"] = group.occurrences
    result["first_seen"] = group.first_seen
    result["last_seen"] = group.last_seen
    return result


def parse_codex_result(result_file: Path, stdout: str) -> Any:
    candidates = []
    if result_file.exists():
        candidates.append(result_file.read_text(encoding="utf-8", errors="replace").strip())
    candidates.append(stdout.strip())
    for candidate in candidates:
        if not candidate:
            continue
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            for line in reversed(candidate.splitlines()):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue
    raise ValueError("Codex output is not valid JSON")


def run_codex(
    config: dict[str, Any],
    prompt: str,
    work_dir: Path,
    result_file: Path,
    schema_file: Path,
) -> tuple[Any, str, float]:
    codex = str(config.get("codex_command", "codex"))
    timeout = int(config.get("timeout_seconds", 300))
    command = [
        codex,
        "exec",
        "--json",
        "--sandbox",
        str(config.get("sandbox", "read-only")),
        "--ask-for-approval",
        str(config.get("ask_for_approval", "never")),
        "--output-schema",
        str(schema_file),
        "--output-last-message",
        str(result_file),
        "-",
    ]
    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=work_dir,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[-2000:]
        raise RuntimeError(f"codex exited {completed.returncode}: {detail}")
    return parse_codex_result(result_file, completed.stdout), completed.stderr[-2000:], elapsed


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    os.replace(temporary, path)


def write_result(results_dir: Path, target_date: dt.date, group: ErrorGroup, result: dict[str, Any]) -> Path:
    target = results_dir / target_date.isoformat() / group.module / f"{group.fingerprint}.json"
    atomic_write(target, json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return target


def write_summary(results_dir: Path, target_date: dt.date, summary: list[dict[str, Any]]) -> None:
    target_dir = results_dir / target_date.isoformat()
    atomic_write(target_dir / "summary.json", json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    lines = [f"# ERROR 根因分析 {target_date.isoformat()}", ""]
    for item in summary:
        lines.extend(
            [
                f"## {item['module']} / `{item['fingerprint'][:12]}`",
                f"- 状态：{item['status']}",
                f"- 次数：{item['occurrences']}",
                f"- 摘要：{item.get('summary', item.get('reason', ''))}",
                "",
            ]
        )
    atomic_write(target_dir / "summary.md", "\n".join(lines))


def main() -> int:
    args = parse_args()
    try:
        config = load_config(args.config)
        timezone = get_timezone(config)
        target_date = local_date(config, args.date)
        modules = iter_modules(config, args.module)
        state_db = config_path(config, "state_db", SCRIPT_DIR / "state.db")
        results_dir = config_path(config, "results_dir", SCRIPT_DIR / "results")
        work_dir = config_path(config, "work_dir", SCRIPT_DIR / "work")
        prompt_file = config_path(config, "prompt_file", DEFAULT_PROMPT)
        schema_file = config_path(config, "schema_file", DEFAULT_SCHEMA)
        deploy_root = config_path(config, "deploy_root", Path("/opt/deploy"))
        samples_per_group = int(config.get("samples_per_group", 3))
        sample_chars = int(config.get("sample_chars", 4000))
        daily_groups = int(config.get("daily_groups", 20))
        total_chars = int(config.get("total_chars", 60000))
        retry_after = int(config.get("retry_after_seconds", 3600))
        error_log_name = str(config.get("error_log_name", "logs/error.log"))
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    work_dir.mkdir(parents=True, exist_ok=True)
    connection = open_database(state_db)
    summary: list[dict[str, Any]] = []
    analyzed = 0
    input_chars = 0
    try:
        for module in modules:
            deploy_dir = discover_deploy_dir(deploy_root, module)
            if deploy_dir is None:
                summary.append({"module": module, "status": "missing_deploy_dir", "occurrences": 0})
                continue
            groups = read_error_groups(
                module,
                deploy_dir / error_log_name,
                target_date,
                timezone,
                samples_per_group,
                sample_chars,
            )
            for group in groups:
                if not should_analyze(connection, group, retry_after):
                    summary.append(
                        {"module": module, "fingerprint": group.fingerprint, "status": "already_success", "occurrences": group.occurrences}
                    )
                    continue
                prompt = load_prompt(prompt_file, group)
                group_chars = len(prompt)
                if analyzed >= daily_groups or input_chars + group_chars > total_chars:
                    if not args.dry_run:
                        upsert_group(connection, group, "skipped", last_error="daily budget exceeded")
                    summary.append(
                        {"module": module, "fingerprint": group.fingerprint, "status": "skipped", "reason": "daily budget exceeded", "occurrences": group.occurrences}
                    )
                    continue
                if args.dry_run:
                    summary.append(
                        {"module": module, "fingerprint": group.fingerprint, "status": "pending", "occurrences": group.occurrences}
                    )
                    analyzed += 1
                    input_chars += group_chars
                    continue
                result_file = work_dir / f"{group.fingerprint}.result.json"
                try:
                    value, stderr, elapsed = run_codex(config, prompt, work_dir, result_file, schema_file)
                    result = validate_result(value, group)
                    result["execution"] = {"elapsed_seconds": round(elapsed, 3), "stderr": stderr}
                    result_path = write_result(results_dir, target_date, group, result)
                    upsert_group(connection, group, "success", result_path=str(result_path))
                    summary.append(
                        {
                            "module": module,
                            "fingerprint": group.fingerprint,
                            "status": "success",
                            "occurrences": group.occurrences,
                            "summary": result.get("summary", ""),
                        }
                    )
                except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
                    upsert_group(connection, group, "failed", last_error=str(exc), increment_attempt=True)
                    summary.append(
                        {
                            "module": module,
                            "fingerprint": group.fingerprint,
                            "status": "failed",
                            "occurrences": group.occurrences,
                            "reason": str(exc),
                        }
                    )
                finally:
                    result_file.unlink(missing_ok=True)
                analyzed += 1
                input_chars += group_chars
        connection.commit()
        write_summary(results_dir, target_date, summary)
    finally:
        connection.close()
    counts: dict[str, int] = {}
    for item in summary:
        counts[item["status"]] = counts.get(item["status"], 0) + 1
    print(
        json.dumps(
            {
                "date": target_date.isoformat(),
                "dry_run": args.dry_run,
                "total_groups": len(summary),
                "status_counts": counts,
            },
            ensure_ascii=False,
        )
    )
    return 0 if not any(item["status"] in {"failed", "missing_deploy_dir"} for item in summary) else 1


if __name__ == "__main__":
    raise SystemExit(main())
