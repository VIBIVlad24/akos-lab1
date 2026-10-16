#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET="$SCRIPT_DIR/script1.sh"
[ -f "$TARGET" ] || { echo "Не найден script1.sh" >&2; exit 1; }

command -v fuse2fs >/dev/null || { echo "Нужен fuse2fs" >&2; exit 1; }
command -v fusermount3 >/dev/null || command -v fusermount >/dev/null || { echo "Нужен fusermount3" >&2; exit 1; }
FUSERMOUNT=$(command -v fusermount3 || command -v fusermount)

TMP_ROOT=$(mktemp -d -t cleanup_test.XXXXXX)
PASS=0
FAIL=0

cleanup() {
    for d in "$TMP_ROOT"/*/log; do
        [ -d "$d" ] || continue
        mountpoint -q "$d" 2>/dev/null && "$FUSERMOUNT" -u "$d" 2>/dev/null
    done
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

hr() { printf '%s\n' "------------------------------------------------------------"; }

assert() {
    local desc="$1"; shift
    if "$@"; then
        printf '  ✓ %s\n' "$desc"; PASS=$((PASS+1))
    else
        printf '  ✗ %s\n' "$desc"; FAIL=$((FAIL+1))
    fi
}

run_case() {
    hr
    printf 'ТЕСТ: %s\n' "$1"
}

make_logs() {
    local mnt="$1" pct="$2" n="${3:-64}"
    local total
    total=$(df -B1 --output=size "$mnt" | tail -1)
    local want=$(( total * pct / 100 ))
    local per=$(( want / n ))
    for ((i=0; i<n; i++)); do
        local f="$mnt/log_$(printf '%04d' "$i").bin"
        head -c "$per" /dev/zero > "$f"
        touch -d "@$(( $(date +%s) - (n - i) * 60 ))" "$f"
    done
}

make_virtual_disk() {
    local case_dir="$1" size_mb="$2"
    mkdir -p "$case_dir"
    local img="$case_dir/log.img"
    local mnt="$case_dir/log"
    truncate --size="${size_mb}M" "$img"
    mkfs.ext4 -q -O ^has_journal -E root_owner="$(id -u):$(id -g)" "$img"
    mkdir -p "$mnt"
    fuse2fs -o "uid=$(id -u),gid=$(id -g),umask=022" "$img" "$mnt"
}

unmount() {
    local mnt="$1"
    mountpoint -q "$mnt" 2>/dev/null && "$FUSERMOUNT" -u "$mnt" 2>/dev/null
}

usage_pct() {
    df -P "$1" | awk 'NR==2 { gsub("%","",$5); print $5 }'
}

# ТЕСТ-КЕЙС 1: порог не превышен
run_case "Порог не превышен (заполнение ~30%)"
C="$TMP_ROOT/t1"; mkdir -p "$C"
make_virtual_disk "$C" 512
make_logs "$C/log" 30
CUR=$(usage_pct "$C/log")
printf '    (заполнение: %s%%)\n' "$CUR"

"$TARGET" "$C/log" 70 | sed 's/^/    /'

assert "архивов не создано" bash -c "[ -z \"\$(ls -A '$C/backup' 2>/dev/null)\" ]"
assert "файлы на месте" bash -c "[ \$(find '$C/log' -maxdepth 1 -type f | wc -l) -eq 64 ]"
assert "log — отдельная ФС"  bash -c "[ \$(df -P '$C/log' | awk 'NR==2 {print \$6}') != '/' ]"

unmount "$C/log"

# ТЕСТ-КЕЙС 2: порог превышен — архивация срабатывает
run_case "Порог превышен (заполнение ~85%) — архивация"
C="$TMP_ROOT/t2"; mkdir -p "$C"
make_virtual_disk "$C" 512
make_logs "$C/log" 85
CUR=$(usage_pct "$C/log")
printf '    (заполнение: %s%%)\n' "$CUR"

"$TARGET" "$C/log" 70 | sed 's/^/    /'

NEW=$(usage_pct "$C/log")
assert "создан архив"            bash -c "ls '$C/backup'/*.tar.gz >/dev/null 2>&1"
assert "новое заполнение <= 70%" bash -c "[ $NEW -le 70 ]"
assert "часть файлов удалена"    bash -c "[ \$(ls -1 '$C/log' | wc -l) -lt 64 ]"
assert "архив валиден"           bash -c "tar -tzf \$(ls '$C/backup'/*.tar.gz | head -1) >/dev/null"

unmount "$C/log"

# ТЕСТ-КЕЙС 3: высокий порог — no-op
run_case "Порог 95% при заполнении ~85% — no-op"
C="$TMP_ROOT/t3"; mkdir -p "$C"
make_virtual_disk "$C" 512
make_logs "$C/log" 85

"$TARGET" "$C/log" 95 | sed 's/^/    /'

assert "архивов нет" bash -c "[ -z \"\$(ls -A '$C/backup' 2>/dev/null)\" ]"
assert "файлы целы" bash -c "[ \$(find '$C/log' -maxdepth 1 -type f | wc -l) -eq 64 ]"

unmount "$C/log"

# ТЕСТ-КЕЙС 4: архивируются самые старые файлы
run_case "Архивируются самые старые файлы"
C="$TMP_ROOT/t4"; mkdir -p "$C"
make_virtual_disk "$C" 512
make_logs "$C/log" 90

OLDEST=$(find "$C/log" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | head -1 | awk '{print $2}')
NEWEST=$(find "$C/log" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | tail -1 | awk '{print $2}')

"$TARGET" "$C/log" 70 | sed 's/^/    /'

ARCHIVE=$(ls "$C/backup"/*.tar.gz | head -1)
assert "самый старый — в архиве" bash -c "tar -tzf '$ARCHIVE' | grep -q '$(basename "$OLDEST")'"
assert "самый старый — удалён"   bash -c "[ ! -e '$OLDEST' ]"
assert "самый новый — на месте"  bash -c "[ -e '$NEWEST' ]"

unmount "$C/log"

# ТЕСТ-КЕЙС 5: пустая папка
run_case "Пустая папка"
C="$TMP_ROOT/t5"; mkdir -p "$C"
make_virtual_disk "$C" 256

"$TARGET" "$C/log" 70 | sed 's/^/    /'

assert "архивов нет" bash -c "[ -z \"\$(ls -A '$C/backup' 2>/dev/null)\" ]"

unmount "$C/log"

hr
printf 'ИТОГО: PASS=%d, FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
