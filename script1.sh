#!/bin/bash

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Использование: $0 <путь> [порог]"
    exit 1
fi

if [ ! -d "$1" ]; then
    echo "Ошибка: '$1' не является директорией."
    exit 1
fi
