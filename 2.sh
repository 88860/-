#!/bin/bash

set -u
export LC_ALL=C

TARGET_MIN=1
TARGET_MAX=10
JOURNAL_MAX=8M

LOGROTATE_MAIN="/etc/logrotate.conf"
LOGROTATE_DIR="/etc/logrotate.d"
JOURNAL_CONF="/etc/systemd/journald.conf"

declare -a LOG_FILES
declare -a LOG_TYPES
declare -a LOG_SIZES
declare -a LOG_CONFIGS
declare -a LOG_LIMITS
declare -a LOG_SUGGESTIONS

declare -a MOD_LOG
declare -a MOD_CFG
declare -a MOD_VALUE
declare -a MOD_STANZA_START
declare -a MOD_STANZA_END

TMP_DIR=""
MOD_COUNT=0
JOURNAL_MOD=0
FAIL_COUNT=0

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

die() {
    echo "错误：$*"
    exit 1
}

[[ $EUID -eq 0 ]] || die "必须使用 root 运行。"

command -v python3 >/dev/null 2>&1 || die "系统缺少 python3。"
command -v logrotate >/dev/null 2>&1 || die "系统缺少 logrotate。"

TMP_DIR="$(mktemp -d)" || die "无法创建临时工作目录。"

clear 2>/dev/null || true

echo "============================================================"
echo " Debian 13 日志大小审计与精准限制"
echo " 扫描 → 识别 → 分类 → 建议 → 确认 → 精准修改 → 验证"
echo "============================================================"
echo
echo "目标：普通日志 1M–10M；journald 单文件 8M"
echo
echo "原则："
echo "  ✓ 只修改真实存在且实际控制日志的配置文件"
echo "  ✓ 按 logrotate stanza 精确识别"
echo "  ✓ 修改后重新解析同一 stanza 验证"
echo "  ✓ 不创建任何配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo "  ✓ 控制关系无法确认 → 跳过"
echo

##############################################################################
# 基础信息
##############################################################################

echo "[1/8] 系统检测"

OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
KERNEL="$(uname -r)"
CPU="$(nproc 2>/dev/null || echo "?")"
RAM_MB="$(awk '/MemTotal:/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)"
VARLOG_SIZE="$(du -sh /var/log 2>/dev/null | awk '{print $1}')"
RUNLOG_SIZE="$(du -sh /run/log 2>/dev/null | awk '{print $1}' 2>/dev/null || echo 0)"

echo "  OS       : $OS_NAME"
echo "  Kernel   : $KERNEL"
echo "  CPU      : ${CPU} cores"
echo "  RAM      : ${RAM_MB:-?} MB"
echo "  /var/log : ${VARLOG_SIZE:-?}"
echo "  /run/log : ${RUNLOG_SIZE:-0}"
echo

##############################################################################
# 扫描日志
##############################################################################

echo "[2/8] 扫描实际日志文件"

mapfile -d '' LOG_FILES < <(
    find /var/log /run/log \
        -xdev \
        -type f \
        -print0 2>/dev/null |
    sort -z
)

LOG_COUNT="${#LOG_FILES[@]}"

echo "  找到 ${LOG_COUNT} 个当前日志文件"
echo

##############################################################################
# 日志分类
##############################################################################

classify_log() {
    local f="$1"

    case "$f" in
        /var/log/dpkg.log)
            echo "dpkg"
            ;;
        /var/log/alternatives.log)
            echo "alternatives"
            ;;
        /var/log/apt/history.log)
            echo "apt-history"
            ;;
        /var/log/apt/term.log)
            echo "apt-terminal"
            ;;
        /var/log/apt/eipp.log.xz)
            echo "apt-planner"
            ;;
        /var/log/btmp)
            echo "failed-login-history"
            ;;
        /var/log/wtmp)
            echo "login-history"
            ;;
        /var/log/lastlog)
            echo "lastlog"
            ;;
        /var/log/wtmp.db)
            echo "wtmp-db"
            ;;
        /var/log/installer/*)
            echo "installer"
            ;;
        /var/log/journal/*.journal/*)
            echo "journald"
            ;;
        /run/log/journal/*.journal/*)
            echo "journald"
            ;;
        /var/log/journal/*/*)
            echo "journald"
            ;;
        /run/log/journal/*/*)
            echo "journald"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

recommend_log() {
    local type="$1"

    case "$type" in
        alternatives)
            echo "2M"
            ;;
        apt-history)
            echo "3M"
            ;;
        apt-terminal)
            echo "5M"
            ;;
        apt-planner)
            echo "SKIP"
            ;;
        dpkg)
            echo "5M"
            ;;
        failed-login-history)
            echo "5M"
            ;;
        login-history)
            echo "5M"
            ;;
        lastlog)
            echo "5M"
            ;;
        wtmp-db)
            echo "SKIP"
            ;;
        installer)
            echo "SKIP"
            ;;
        journald)
            echo "SKIP"
            ;;
        *)
            echo "SKIP"
            ;;
    esac
}

human_size() {
    local bytes="$1"

    if (( bytes >= 1073741824 )); then
        awk -v n="$bytes" 'BEGIN {printf "%.2fG", n/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v n="$bytes" 'BEGIN {printf "%.2fM", n/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v n="$bytes" 'BEGIN {printf "%.2fK", n/1024}'
    else
        echo "${bytes}B"
    fi
}

##############################################################################
# 精确解析 logrotate
##############################################################################

echo "[3/8] 精确检测 logrotate 控制关系"
echo

python3 - "$LOGROTATE_MAIN" "$LOGROTATE_DIR" "$TMP_DIR/stanzas" <<'PY'
import os
import sys
import glob
import re

main = sys.argv[1]
directory = sys.argv[2]
out = sys.argv[3]

files = []

if os.path.isfile(main):
    files.append(main)

if os.path.isdir(directory):
    for p in sorted(glob.glob(directory + "/*")):
        if os.path.isfile(p) and not os.path.islink(p):
            files.append(p)

def strip_comment(line):
    out = []
    quote = None
    esc = False

    for c in line:
        if esc:
            out.append(c)
            esc = False
            continue

        if c == "\\":
            out.append(c)
            esc = True
            continue

        if quote:
            out.append(c)
            if c == quote:
                quote = None
            continue

        if c in ("'", '"'):
            quote = c
            out.append(c)
            continue

        if c == "#":
            break

        out.append(c)

    return "".join(out)

records = []

for path in files:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception:
        continue

    depth = 0
    start = None
    header = ""
    body = []

    for idx, raw in enumerate(lines, start=1):
        line = strip_comment(raw).strip()

        if start is None:
            if not line:
                continue

            if "{" in line:
                before = line.split("{", 1)[0].strip()

                if before:
                    start = idx
                    header = before
                    body = []
                    depth = line.count("{") - line.count("}")

                    if depth <= 0:
                        records.append((path, start, idx, header, body))
                        start = None
                        header = ""
                        body = []
            continue

        body.append(raw)

        depth += line.count("{")
        depth -= line.count("}")

        if depth <= 0:
            records.append((path, start, idx, header, body))
            start = None
            header = ""
            body = []
            depth = 0

with open(out, "w", encoding="utf-8") as f:
    for path, start, end, header, body in records:
        f.write("FILE\t%s\n" % path)
        f.write("START\t%d\n" % start)
        f.write("END\t%d\n" % end)
        f.write("HEADER\t%s\n" % header.replace("\t", " "))
        f.write("BODY_BEGIN\n")
        for line in body:
            f.write(line.rstrip("\n") + "\n")
        f.write("BODY_END\n")
PY

##############################################################################
# 建立真实控制关系
##############################################################################

declare -A FOUND_CFG
declare -A FOUND_START
declare -A FOUND_END
declare -A FOUND_HEADER
declare -A FOUND_LIMIT

current_file=""
current_start=""
current_end=""
current_header=""
body=""

parse_record() {
    local target="$1"

    local header="$current_header"
    local body_text="$body"

    python3 - "$target" "$header" "$body_text" <<'PY'
import sys
import re
import shlex

target = sys.argv[1]
header = sys.argv[2]
body = sys.argv[3]

def clean_token(x):
    x = x.strip()
    if len(x) >= 2 and x[0] == x[-1] and x[0] in "\"'":
        x = x[1:-1]
    return x

try:
    tokens = shlex.split(header, comments=False, posix=True)
except Exception:
    tokens = header.split()

matches = []

for token in tokens:
    token = clean_token(token)

    if token == target:
        matches.append(token)
        continue

    if "*" in token or "?" in token or "[" in token:
        import fnmatch
        if fnmatch.fnmatch(target, token):
            matches.append(token)

if not matches:
    sys.exit(1)

limit = "UNSET"
lines = body.splitlines()

for line in lines:
    s = line.strip()

    if not s or s.startswith("#"):
        continue

    m = re.match(r'^(?:maxsize)\s+(\S+)', s, re.I)
    if m:
        limit = "maxsize " + m.group(1)
        break

    m = re.match(r'^(?:size)\s+(\S+)', s, re.I)
    if m:
        limit = "size " + m.group(1)
        break

print(limit)
PY
}

declare -A CFG_FOR_LOG
declare -A START_FOR_LOG
declare -A END_FOR_LOG
declare -A LIMIT_FOR_LOG

while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        FILE$'\t'*)
            current_file="${line#FILE	}"
            ;;
        START$'\t'*)
            current_start="${line#START	}"
            ;;
        END$'\t'*)
            current_end="${line#END	}"
            ;;
        HEADER$'\t'*)
            current_header="${line#HEADER	}"
            ;;
        BODY_BEGIN)
            body=""
            ;;
        BODY_END)
            for lf in "${LOG_FILES[@]}"; do
                result="$(
                    parse_record "$lf" 2>/dev/null || true
                )"

                if [[ -n "$result" ]]; then
                    if [[ -z "${CFG_FOR_LOG[$lf]:-}" ]]; then
                        CFG_FOR_LOG["$lf"]="$current_file"
                        START_FOR_LOG["$lf"]="$current_start"
                        END_FOR_LOG["$lf"]="$current_end"
                        LIMIT_FOR_LOG["$lf"]="$result"
                    fi
                fi
            done
            ;;
        *)
            if [[ -n "$current_file" ]]; then
                body+="$line"$'\n'
            fi
            ;;
    esac
done < "$TMP_DIR/stanzas"

CONTROL_COUNT=0

for lf in "${LOG_FILES[@]}"; do
    if [[ -n "${CFG_FOR_LOG[$lf]:-}" ]]; then
        CONTROL_COUNT=$((CONTROL_COUNT + 1))
    fi
done

UNKNOWN_COUNT=$((LOG_COUNT - CONTROL_COUNT))

echo "  已识别明确控制关系：${CONTROL_COUNT}"
echo "  未找到控制关系    ：${UNKNOWN_COUNT}"
echo

##############################################################################
# journald
##############################################################################

echo "[4/8] 检测 systemd-journald"
echo

PERSISTENT_JOURNAL=0
RUNTIME_JOURNAL=0

if find /var/log/journal -type f -name '*.journal' -print -quit 2>/dev/null | grep -q .; then
    PERSISTENT_JOURNAL=1
fi

if find /run/log/journal -type f -name '*.journal' -print -quit 2>/dev/null | grep -q .; then
    RUNTIME_JOURNAL=1
fi

get_journal_value() {
    local key="$1"

    if [[ -f "$JOURNAL_CONF" ]]; then
        awk -v k="$key" '
            /^[[:space:]]*#/ {next}
            $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, "", $0)
                print $0
            }
        ' "$JOURNAL_CONF" | tail -n1
    fi
}

SYSTEM_JOURNAL_VALUE="$(get_journal_value SystemMaxFileSize)"
RUNTIME_JOURNAL_VALUE="$(get_journal_value RuntimeMaxFileSize)"

echo "  persistent journal : ${PERSISTENT_JOURNAL}"
echo "  runtime journal    : ${RUNTIME_JOURNAL}"
echo "  SystemMaxFileSize  : ${SYSTEM_JOURNAL_VALUE:-未设置}"
echo "  RuntimeMaxFileSize : ${RUNTIME_JOURNAL_VALUE:-未设置}"
echo

##############################################################################
# 所有日志表
##############################################################################

echo "[5/8] 所有日志及控制关系"
echo

printf "%-48s %-21s %-10s %-34s %-14s %-8s\n" \
    "日志" "类型" "大小" "真实控制文件" "当前限制" "建议"

echo "---------------------------------------------------------------------------------------------------------------"

for lf in "${LOG_FILES[@]}"; do
    type="$(classify_log "$lf")"
    size_bytes="$(stat -c '%s' "$lf" 2>/dev/null || echo 0)"
    size="$(human_size "$size_bytes")"
    cfg="${CFG_FOR_LOG[$lf]:-未找到}"
    limit="${LIMIT_FOR_LOG[$lf]:-未设置}"
    suggestion="$(recommend_log "$type")"

    LOG_TYPES+=("$type")
    LOG_SIZES+=("$size")
    LOG_CONFIGS+=("$cfg")
    LOG_LIMITS+=("$limit")
    LOG_SUGGESTIONS+=("$suggestion")

    printf "%-48s %-21s %-10s %-34s %-14s %-8s\n" \
        "$lf" "$type" "$size" "$cfg" "$limit" "$suggestion"
done

echo

##############################################################################
# 生成修改计划
##############################################################################

echo "[6/8] 修改建议"
echo
echo "建议依据：日志用途，不依据当前文件大小。"
echo

for i in "${!LOG_FILES[@]}"; do
    lf="${LOG_FILES[$i]}"
    type="${LOG_TYPES[$i]}"
    cfg="${LOG_CONFIGS[$i]}"
    suggestion="${LOG_SUGGESTIONS[$i]}"
    limit="${LOG_LIMITS[$i]}"

    [[ "$suggestion" == "SKIP" ]] && continue
    [[ "$cfg" == "未找到" ]] && continue

    if [[ "$limit" == "maxsize $suggestion" ]]; then
        continue
    fi

    if [[ "$limit" == "size $suggestion" ]]; then
        continue
    fi

    MOD_LOG[$MOD_COUNT]="$lf"
    MOD_CFG[$MOD_COUNT]="$cfg"
    MOD_VALUE[$MOD_COUNT]="$suggestion"
    MOD_STANZA_START[$MOD_COUNT]="${START_FOR_LOG[$lf]}"
    MOD_STANZA_END[$MOD_COUNT]="${END_FOR_LOG[$lf]}"

    MOD_COUNT=$((MOD_COUNT + 1))

    echo "[$MOD_COUNT]"
    echo "  日志       : $lf"
    echo "  类型       : $type"
    echo "  控制文件   : $cfg"
    echo "  stanza     : ${START_FOR_LOG[$lf]}-${END_FOR_LOG[$lf]}"
    echo "  当前限制   : ${limit}"
    echo "  修改目标   : maxsize ${suggestion}"
    echo
done

##############################################################################
# journald 修改计划
##############################################################################

if [[ -f "$JOURNAL_CONF" ]]; then
    if [[ "$SYSTEM_JOURNAL_VALUE" != "$JOURNAL_MAX" ]]; then
        JOURNAL_MOD=1
    fi

    if [[ "$RUNTIME_JOURNAL_VALUE" != "$JOURNAL_MAX" ]]; then
        JOURNAL_MOD=1
    fi
fi

if (( MOD_COUNT == 0 && JOURNAL_MOD == 0 )); then
    echo "没有需要修改的配置。"
    echo
    echo "当前所有可确认控制关系均符合目标。"
    exit 0
fi

if (( JOURNAL_MOD )); then
    echo "[journald]"
    echo "  控制文件 : $JOURNAL_CONF"

    if [[ "$SYSTEM_JOURNAL_VALUE" == "$JOURNAL_MAX" ]]; then
        echo "  SystemMaxFileSize  : 已是 $JOURNAL_MAX"
    else
        echo "  SystemMaxFileSize  : ${SYSTEM_JOURNAL_VALUE:-未设置} → $JOURNAL_MAX"
    fi

    if [[ "$RUNTIME_JOURNAL_VALUE" == "$JOURNAL_MAX" ]]; then
        echo "  RuntimeMaxFileSize : 已是 $JOURNAL_MAX"
    else
        echo "  RuntimeMaxFileSize : ${RUNTIME_JOURNAL_VALUE:-未设置} → $JOURNAL_MAX"
    fi

    echo
fi

echo "[7/8] 修改原则"
echo
echo "  ✓ 只修改真实存在的控制配置"
echo "  ✓ 只修改目标日志所属 stanza"
echo "  ✓ 修改后重新解析同一 stanza"
echo "  ✓ maxsize 按日志用途设置 1M–10M"
echo "  ✓ journald 单文件限制 8M"
echo "  ✓ 未确认控制关系的日志跳过"
echo "  ✓ 不创建配置文件"
echo "  ✓ 不备份"
echo "  ✓ 不删除现有日志"
echo

echo "============================================================"
echo "                         安全确认"
echo "============================================================"
echo

echo "本次准备修改：${MOD_COUNT} 个 logrotate stanza"

if (( JOURNAL_MOD )); then
    echo "journald：需要修改 $JOURNAL_CONF"
else
    echo "journald：无需修改"
fi

echo
echo "⚠ 不创建任何配置文件"
echo "⚠ 不备份"
echo "⚠ 不删除现有日志"
echo

read -r -p "确认执行精准修改？[y/N] " ANSWER
echo

[[ "$ANSWER" =~ ^[Yy]$ ]] || {
    echo "已取消，未修改任何配置。"
    exit 0
}

##############################################################################
# 修改 logrotate
##############################################################################

echo "============================================================"
echo "                         开始修改"
echo "============================================================"
echo

for ((i=0; i<MOD_COUNT; i++)); do
    lf="${MOD_LOG[$i]}"
    cfg="${MOD_CFG[$i]}"
    value="${MOD_VALUE[$i]}"
    start="${MOD_STANZA_START[$i]}"
    end="${MOD_STANZA_END[$i]}"

    python3 - "$cfg" "$lf" "$value" "$start" "$end" <<'PY'
import sys
import re

path = sys.argv[1]
target = sys.argv[2]
value = sys.argv[3]
start = int(sys.argv[4])
end = int(sys.argv[5])

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

if start < 1 or end > len(lines) or start > end:
    raise SystemExit("stanza 行范围无效")

header_index = start - 1
brace_index = None

for i in range(start - 1, end):
    if "{" in lines[i]:
        brace_index = i
        break

if brace_index is None:
    raise SystemExit("找不到 stanza 起始 {")

# 再次确认 header 真正包含目标日志
header = lines[header_index:brace_index + 1]
header_text = "".join(header)

if target not in header_text:
    raise SystemExit("目标日志与 stanza 不匹配，拒绝修改")

depth = 0
close_index = None

for i in range(brace_index, end):
    depth += lines[i].count("{")
    depth -= lines[i].count("}")

    if depth == 0:
        close_index = i
        break

if close_index is None:
    raise SystemExit("找不到 stanza 结束 }")

directive = f"maxsize {value}\n"

# 只在当前 stanza 内寻找 size/maxsize
found = None

for i in range(brace_index + 1, close_index):
    raw = lines[i]

    if re.match(r'^\s*#\s*maxsize\s+\S+', raw, re.I):
        found = ("commented", i)
        break

    if re.match(r'^\s*maxsize\s+\S+', raw, re.I):
        found = ("maxsize", i)
        break

    if re.match(r'^\s*size\s+\S+', raw, re.I):
        found = ("size", i)
        break

if found:
    kind, idx = found

    if kind == "size":
        # 已经存在 size 时，不覆盖它。
        # size 与 maxsize 语义不同，避免破坏原配置。
        raise SystemExit("当前 stanza 已存在 size，拒绝强行改写")

    indent = re.match(r'^(\s*)', lines[idx]).group(1)
    lines[idx] = indent + directive

else:
    # 插入到 close brace 前
    indent = "  "
    lines.insert(close_index, indent + directive)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

    if [[ $? -eq 0 ]]; then
        echo "✓ $cfg"
        echo "  $lf → maxsize $value"
    else
        echo "✗ $cfg"
        echo "  $lf → 修改失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

##############################################################################
# 修改 journald
##############################################################################

if (( JOURNAL_MOD )); then
    python3 - "$JOURNAL_CONF" "$JOURNAL_MAX" <<'PY'
import sys
import re

path = sys.argv[1]
value = sys.argv[2]

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

keys = {
    "SystemMaxFileSize": False,
    "RuntimeMaxFileSize": False,
}

for i, raw in enumerate(lines):
    m = re.match(
        r'^(\s*)(#\s*)?(SystemMaxFileSize|RuntimeMaxFileSize)\s*=\s*(\S+)(\s*(?:#.*)?)$',
        raw
    )

    if not m:
        continue

    indent = m.group(1)
    commented = m.group(2)

    key = m.group(3)
    suffix = m.group(5) or ""

    lines[i] = f"{indent}{key}={value}{suffix}\n"
    keys[key] = True

missing = [k for k, found in keys.items() if not found]

if missing:
    section = None

    for i, raw in enumerate(lines):
        if raw.strip().lower() == "[journal]":
            section = i
            break

    if section is None:
        raise SystemExit("[Journal] section 不存在，拒绝创建配置结构")

    insert_at = len(lines)

    for i in range(section + 1, len(lines)):
        if re.match(r'^\s*\[.*\]\s*$', lines[i]):
            insert_at = i
            break

    block = []
    for key in missing:
        block.append(f"{key}={value}\n")

    lines[insert_at:insert_at] = block

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

    if [[ $? -eq 0 ]]; then
        echo "✓ $JOURNAL_CONF"
        echo "  SystemMaxFileSize=$JOURNAL_MAX"
        echo "  RuntimeMaxFileSize=$JOURNAL_MAX"
    else
        echo "✗ $JOURNAL_CONF 修改失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

##############################################################################
# logrotate 语法验证
##############################################################################

echo
echo "============================================================"
echo "                     验证 logrotate"
echo "============================================================"

if logrotate -d "$LOGROTATE_MAIN" >/dev/null 2>&1; then
    echo "✓ logrotate 配置语法正常"
else
    echo "✗ logrotate 配置语法检查失败"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

##############################################################################
# 重新解析验证
##############################################################################

echo
echo "============================================================"
echo "              精确验证修改后的 logrotate stanza"
echo "============================================================"

for ((i=0; i<MOD_COUNT; i++)); do
    lf="${MOD_LOG[$i]}"
    cfg="${MOD_CFG[$i]}"
    expected="${MOD_VALUE[$i]}"
    start="${MOD_STANZA_START[$i]}"
    end="${MOD_STANZA_END[$i]}"

    result="$(
        python3 - "$cfg" "$lf" "$expected" "$start" "$end" <<'PY'
import sys
import re

path = sys.argv[1]
target = sys.argv[2]
expected = sys.argv[3]
start = int(sys.argv[4])
end = int(sys.argv[5])

with open(path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

if start < 1 or end > len(lines):
    sys.exit(2)

brace = None
depth = 0
close = None

for i in range(start - 1, end):
    if brace is None and "{" in lines[i]:
        brace = i

    if brace is not None:
        depth += lines[i].count("{")
        depth -= lines[i].count("}")

        if depth == 0:
            close = i
            break

if brace is None or close is None:
    sys.exit(3)

header = "".join(lines[start - 1:brace + 1])

if target not in header:
    sys.exit(4)

found = []

for i in range(brace + 1, close):
    s = lines[i].strip()

    if not s or s.startswith("#"):
        continue

    m = re.match(r'^maxsize\s+(\S+)', s, re.I)
    if m:
        found.append(m.group(1))

if len(found) != 1:
    print("INVALID")
    sys.exit(5)

if found[0].lower() != expected.lower():
    print(found[0])
    sys.exit(6)

print("maxsize " + found[0])
PY
    )"

    rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "✓ $lf : $result"
    else
        if [[ "$result" == "INVALID" ]]; then
            echo "✗ $lf : 当前 stanza 中 maxsize 不唯一或不存在"
        elif [[ -n "$result" ]]; then
            echo "✗ $lf : 期望 maxsize $expected，实际 $result"
        else
            echo "✗ $lf : 无法验证目标 stanza"
        fi

        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

##############################################################################
# journald 验证
##############################################################################

if (( JOURNAL_MOD )); then
    echo
    echo "============================================================"
    echo "                    验证 journald"
    echo "============================================================"

    SYSTEM_AFTER="$(get_journal_value SystemMaxFileSize)"
    RUNTIME_AFTER="$(get_journal_value RuntimeMaxFileSize)"

    if [[ "$SYSTEM_AFTER" == "$JOURNAL_MAX" ]]; then
        echo "✓ SystemMaxFileSize = $SYSTEM_AFTER"
    else
        echo "✗ SystemMaxFileSize = ${SYSTEM_AFTER:-未设置}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [[ "$RUNTIME_AFTER" == "$JOURNAL_MAX" ]]; then
        echo "✓ RuntimeMaxFileSize = $RUNTIME_AFTER"
    else
        echo "✗ RuntimeMaxFileSize = ${RUNTIME_AFTER:-未设置}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

##############################################################################
# 最终结果
##############################################################################

echo
echo "============================================================"
echo "                         最终结果"
echo "============================================================"

if (( FAIL_COUNT == 0 )); then
    echo "✓ 所有修改均通过精确验证"
    echo
    echo "配置修改完成。"
    echo
    echo "注意："
    echo "  logrotate 的 maxsize 是轮转触发条件，不是文件系统级硬上限。"
    echo "  journald 的 SystemMaxFileSize / RuntimeMaxFileSize 是单个 journal 文件限制。"
    exit 0
else
    echo "⚠ 验证失败：${FAIL_COUNT} 项"
    echo
    echo "请勿忽略上述失败项目。"
    exit 1
fi
