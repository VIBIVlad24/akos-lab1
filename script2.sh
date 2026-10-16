#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Запустите через sudo (нужен root для loop-монтирования)" >&2
    exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT1="$SCRIPT_DIR/script1.sh"
[[ -f "$SCRIPT1" ]] || { echo "Не найден script1.sh: $SCRIPT1" >&2; exit 1; }

BACKUP_DIR="/backup"

TMP_ROOT=$(mktemp -d -t cleanup_test.XXXXXX)
LOG_DIR="$TMP_ROOT/log"
DISK_IMG="$TMP_ROOT/log_disk.img"
LOOP_DEV=""

PASS=0
FAIL=0

hr() { printf '%s\n' "------------------------------------------------------------"; }

run_case() {
    local title="$1"
    hr
    printf 'ТЕСТ: %s\n' "$title"
}

assert() {
    local desc="$1"; shift
    if "$@"; then
        printf '  ✓ %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf '  ✗ %s\n' "$desc"
        FAIL=$((FAIL + 1))
    fi
}

make_logs() {
    local dir="$1" disk="$2" n="${3:-64}" volume="${4:-1024}" file_size="${5:-1048576}"

    mkdir -p "$dir"
    truncate --size="${volume}M" "$disk"

    LOOP_DEV=$(losetup --find --show "$disk")
    mkfs.ext4 -q -F -m 0 "$LOOP_DEV"
    mount "$LOOP_DEV" "$dir"

    local now i file
    now=$(date +%s)
    for ((i = 0; i < n; i++)); do
        printf -v file '%s/log_%04d.bin' "$dir" "$i"
        fallocate -l "$file_size" "$file"
        touch -d "@$(( now - (n - i) * 60 ))" "$file"
    done
}

unmount() {
    local dir="$1" loop="$2"
    if mountpoint -q "$dir" 2>/dev/null; then
        umount "$dir"
    fi
    if [[ -n "$loop" && -b "$loop" ]]; then
        losetup --detach "$loop"
    fi
}

cleanup() {
    unmount "$LOG_DIR" "$LOOP_DEV"
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

reset_state() {
    unmount "$LOG_DIR" "$LOOP_DEV"
    LOOP_DEV=""
    rm -rf "$LOG_DIR" "$DISK_IMG"
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
}

count_log_files() {
    find "$LOG_DIR" -type f 2>/dev/null | wc -l
}

count_backups() {
    find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | wc -l
}

usage_pct() {
    df --output=pcent "$LOG_DIR" | awk 'NR==2 {gsub("%","",$1); print $1}'
}

# Тест 1: порог не превышен — архивация не запускается

run_case "Порог не превышен (6% из 1024 МБ, порог по умолчанию 70%)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 64 1024 1048576

BEFORE=$(count_log_files)
"$SCRIPT1" "$LOG_DIR" >/dev/null
AFTER=$(count_log_files)

assert "число файлов не изменилось" test "$BEFORE" -eq "$AFTER"
assert "архивы не созданы"          test "$(count_backups)" -eq 0
reset_state

# Тест 2: порог не превышен при явном значении

run_case "Порог не превышен (100 МБ из 512 МБ = ~20%, порог 50%)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 100 512 1048576

BEFORE=$(count_log_files)
"$SCRIPT1" "$LOG_DIR" 50 >/dev/null
AFTER=$(count_log_files)

assert "число файлов не изменилось" test "$BEFORE" -eq "$AFTER"
assert "архивы не созданы"          test "$(count_backups)" -eq 0
reset_state

# Тест 3: порог превышен — срабатывает архивация

run_case "Порог превышен (350 МБ из 512 МБ = ~68%, порог 20%)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 350 512 1048576

BEFORE=$(count_log_files)
"$SCRIPT1" "$LOG_DIR" 20 >/dev/null
AFTER=$(count_log_files)
NEW_PCT=$(usage_pct)

assert "создан ровно один архив"     test "$(count_backups)" -eq 1
assert "часть файлов удалена"        test "$AFTER" -lt "$BEFORE"
assert "заполнение упало до <= 20%"  test "$NEW_PCT" -le 20
ARCHIVE=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | head -1)
assert "архив валиден"               tar -tzf "$ARCHIVE" -q
reset_state

# Тест 4: порог почти максимальный — архивация не запускается

run_case "Порог почти максимальный (6% из 1024 МБ, порог 99%)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 64 1024 1048576

BEFORE=$(count_log_files)
"$SCRIPT1" "$LOG_DIR" 99 >/dev/null
AFTER=$(count_log_files)

assert "число файлов не изменилось" test "$BEFORE" -eq "$AFTER"
assert "архивы не созданы"          test "$(count_backups)" -eq 0
reset_state

# Тест 5: порог почти минимальный, заполнение меньше порога

run_case "Порог почти минимальный (40 МБ из 2048 МБ = ~2%, порог 5%)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 40 2048 1048576

BEFORE=$(count_log_files)
"$SCRIPT1" "$LOG_DIR" 5 >/dev/null
AFTER=$(count_log_files)

assert "число файлов не изменилось" test "$BEFORE" -eq "$AFTER"
assert "архивы не созданы"          test "$(count_backups)" -eq 0
reset_state

# Тест 6: пустая папка — скрипт не падает

run_case "Пустая папка — корректный выход"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 0 256 1048576

assert "в папке нет файлов"  test "$(count_log_files)" -eq 0
"$SCRIPT1" "$LOG_DIR" >/dev/null
assert "архивы не созданы"   test "$(count_backups)" -eq 0
reset_state

# Тест 7: архивируются именно самые старые файлы

run_case "Архивируются самые старые файлы (проверка по mtime)"
reset_state
make_logs "$LOG_DIR" "$DISK_IMG" 350 512 1048576

OLDEST=$(find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | head -1 | awk '{print $2}')
NEWEST=$(find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | tail -1 | awk '{print $2}')

"$SCRIPT1" "$LOG_DIR" 20 >/dev/null
ARCHIVE=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | head -1)

assert "самый старый файл в архиве"       bash -c "tar -tzf '$ARCHIVE' | grep -q '$(basename "$OLDEST")'"
assert "самый старый файл удалён из /log" test ! -e "$OLDEST"
assert "самый новый файл остался в /log"  test -e "$NEWEST"
reset_state

# Итоги

hr
printf 'ИТОГО: PASS=%d, FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]