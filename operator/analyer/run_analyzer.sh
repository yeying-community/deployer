#!/usr/bin/env bash
set -u
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${ANALYZER_CONFIG:-${script_dir}/analyzer.conf}"
ops_home="${YEYING_OPS_HOME:-/root/.codex/skills/yeying-ops}"
workflow="${ops_home}/scripts/ops_workflow.py"
dry_run=0
for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then
    dry_run=1
    break
  fi
done

if [[ ! -f "${workflow}" ]]; then
  printf 'ERROR: installed yeying-ops workflow not found: %s\n' "${workflow}" >&2
  exit 2
fi

set +e
# The production Codex key is exported after the interactive guard in
# /root/.bashrc, so use an interactive shell to load that existing environment.
bash_command="${BASH_COMMAND_PATH:-$(command -v bash)}"
if [[ -z "${bash_command}" || ! -x "${bash_command}" ]]; then
  printf 'ERROR: bash executable not found: %s\n' "${bash_command:-<empty>}" >&2
  exit 2
fi
"${bash_command}" -ic 'exec "$0" -B "$1" run --config "$2" "${@:3}"' \
  /usr/bin/python3 "${workflow}" "${config_file}" "$@"
analyzer_status=$?
set -e
/usr/bin/python3 - "$script_dir" "$config_file" "$analyzer_status" "$dry_run" "$@" <<'PY'
import json, os, subprocess, sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
script_dir = Path(sys.argv[1])
config_file = Path(sys.argv[2]).expanduser().resolve()
config = json.loads(config_file.read_text(encoding="utf-8"))
exit_code = int(sys.argv[3])
dry_run = sys.argv[4] == "1"
arguments = sys.argv[5:]
target_date = next((arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == "--date"), None)
if target_date is None:
    target_date = datetime.now(ZoneInfo(config.get("timezone", "Asia/Shanghai"))).date().isoformat()
results_dir = Path(config.get("results_dir", "results")).expanduser()
if not results_dir.is_absolute():
    results_dir = config_file.parent / results_dir
summary_file = results_dir / target_date / "summary.json"
counts, categories, top = {}, {}, []
if summary_file.exists():
    rows = json.loads(summary_file.read_text(encoding="utf-8"))
    rows_by_occurrence = sorted(rows, key=lambda row: row.get("occurrences", 0), reverse=True)
    for row in rows:
        status = row.get("status", "unknown")
        counts[status] = counts.get(status, 0) + 1
        category = row.get("category")
        if status == "success" and category:
            categories[category] = categories.get(category, 0) + 1
    for row in rows_by_occurrence:
        if row.get("status") == "success" and len(top) < 5:
            category = row.get("category", "unknown")
            top.append(f"- [{category}][{row.get('occurrences', 0)}次] {(row.get('summary') or '')[:160]}")
else:
    rows = []
total_occurrences = sum(row.get("occurrences", 0) for row in rows)
skipped_occurrences = sum(row.get("occurrences", 0) for row in rows if row.get("status") == "skipped")
category_text = "，".join(f"{key} {value}" for key, value in sorted(categories.items())) or "无"
message = ["【ERROR 根因分析与审计日报】", f"日期：{target_date}", f"分组：成功 {counts.get('success', 0)}，失败 {counts.get('failed', 0)}，跳过 {counts.get('skipped', 0)}，今日已分析 {counts.get('already_analyzed', 0)}", f"根因分类：{category_text}", f"覆盖：{total_occurrences} 条告警，跳过组涉及 {skipped_occurrences} 条"]
if top: message += ["", "【重点结果】", *top]
message += ["", f"分析器退出码：{exit_code}"]
notify = Path(os.environ.get("YEYING_OPS_NOTIFY_SCRIPT", script_dir / "../feishu-notify/feishu_reminder.py")).expanduser()
if not dry_run and notify.exists():
    scenario = os.environ.get("YEYING_OPS_NOTIFY_SCENARIO", "monitor_service")
    try:
        subprocess.run(["/usr/bin/python3", str(notify), scenario, "--message", "\n".join(message)], check=False, timeout=20)
    except subprocess.TimeoutExpired:
        print("WARNING: notification timed out after 20 seconds", file=sys.stderr)
PY
exit "$analyzer_status"
