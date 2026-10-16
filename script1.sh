#!/bin/bash

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Использование: $0 <путь> [порог]"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo "Ошибка: '$1' не является директорией."
    exit 1
fi

path="$1"
threshold="${2:-70}"

if ! [[ "$threshold" =~ ^-?[0-9]+$ ]]; then
    echo "Ошибка: порог должен быть числом"
    exit 1
fi

if [ "$threshold" -gt 100 ]; then
    threshold=100
elif [ "$threshold" -lt 0 ]; then
    threshold=0
fi


backup="$(dirname "$path")/backup"

if [ ! -d "$backup" ]; then
    mkdir -p "$backup"
    echo "Создана папка для архивов: $backup"
fi

while true; do
    usage=$(df --output=pcent "$path" | tail -1 | tr -d ' %')

    if [ "$usage" -le "$threshold" ]; then
        echo "Заполнение в норме: $usage% (порог $threshold%)"
        break
    else
        echo "Заполнение $usage% превышает порог $threshold% - нужна архивация"

        fs_size=$(df -B1 --output=size "$path" | tail -1)
        diff=$((usage - threshold))
        needed=$((fs_size * diff / 100))

        echo "Нужно освободить: $needed байт"

        total=0
        files=()
        while read -r time filepath; do
            size=$(stat -c %s "$filepath")
            files+=("$filepath")
            total=$((total + size))
            echo "Отобран: $filepath ($size байт), сумма: $total"
            if [ "$total" -ge "$needed" ]; then
                break
            fi
        done < <(find "$path" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n)

        echo "Итого отобрано: ${#files[@]} файлов на $total байт"

        if [ "${#files[@]}" -eq 0 ]; then
            echo "Нет файлов для архивации"
            break
        fi

        timestamp=$(date +%Y%m%d_%H%M%S)
        archive_name="archive_$timestamp.tar.gz"
        archive_path="$backup/$archive_name"
        echo "Создаю архив: $archive_path"

        tar -czf "$archive_path" -C "$path" -- "${files[@]##*/}"

        echo "Удаляю заархивированные файлы..."
        for f in "${files[@]}"; do
            rm -f "$f"
        done
        echo "Удалено файлов: ${#files[@]}"
    fi
done

echo "Готово."
