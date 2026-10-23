#!/usr/bin/env bash
set -u
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="${ANALYZER_CONFIG:-${script_dir}/analyzer.conf}"
ops_home="${YEYING_OPS_HOME:-/root/.codex/skills/yeying-ops}"
workflow="${ops_home}/scripts/ops_workflow.py"

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
/usr/bin/python3 - "$config_file" "$analyzer_status" <<'PY'
import json, subprocess, sys
from datetime import date
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
exit_code = int(sys.argv[2])
summary_file = Path(config.get("results_dir", "results")) / date.today().isoformat() / "summary.json"
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
message = ["【ERROR 根因分析与审计日报】", f"日期：{date.today().isoformat()}", f"分组：成功 {counts.get('success', 0)}，失败 {counts.get('failed', 0)}，跳过 {counts.get('skipped', 0)}，今日已分析 {counts.get('already_analyzed', 0)}", f"根因分类：{category_text}", f"覆盖：{total_occurrences} 条告警，跳过组涉及 {skipped_occurrences} 条"]
if top: message += ["", "【重点结果】", *top]
message += ["", f"分析器退出码：{exit_code}"]
notify = Path("/root/code/deployer/operator/feishu-notify/feishu_reminder.py")
if notify.exists():
    subprocess.run(["/usr/bin/python3", str(notify), "monitor_service", "--message", "\n".join(message)], check=False)
PY
exit "$analyzer_status"
