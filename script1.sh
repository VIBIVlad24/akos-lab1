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


usage=$(df --output=pcent "$path" | tail -1 | tr -d ' %')

echo "Заполнение: $usage%, порог: $threshold%"