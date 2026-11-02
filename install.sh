#!/usr/bin/env bash

set -e

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/uptimka"
SCRIPT_NAME="uptimka"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Пожалуйста, запустите установщик с правами root (через sudo)."
    exit 1
fi

echo "==============================================="
echo "   Добро пожаловать в установщик uptimka   "
echo "==============================================="
echo ""

read -rp "Введите Telegram Bot Token: " USER_TOKEN < /dev/tty
read -rp "Введите Telegram Chat ID: " USER_CHAT_ID < /dev/tty

read -rp "Порог срабатывания CPU в % [по умолчанию: 85]: " USER_CPU < /dev/tty
USER_CPU=${USER_CPU:-85}

read -rp "Порог срабатывания RAM в % [по умолчанию: 90]: " USER_RAM < /dev/tty
USER_RAM=${USER_RAM:-90}

read -rp "Порог заполнения диска в % [по умолчанию: 90]: " USER_DISK < /dev/tty
USER_DISK=${USER_DISK:-90}

read -rp "Интервал проверки в минутах [по умолчанию: 5]: " USER_INTERVAL < /dev/tty
USER_INTERVAL=${USER_INTERVAL:-5}

echo ""
echo "⏳ Проверка связи с Telegram..."
TEST_MSG="✅ <b>uptimka успешно установлен!</b>
🖥 Хост: <code>$(hostname)</code>"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot${USER_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${USER_CHAT_ID}" \
    --data-urlencode "text=${TEST_MSG}" \
    -d "parse_mode=HTML")

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "❌ Ошибка отправки тестового сообщения (HTTP $HTTP_STATUS)."
    echo "Проверьте корректность Bot Token и Chat ID."
    exit 1
fi

echo "✅ Тестовое уведомление успешно доставлено в Telegram!"

mkdir -p "$CONFIG_DIR"
cat <<EOF > "${CONFIG_DIR}/uptimka.conf"
# Конфигурация uptimka
BOT_TOKEN="${USER_TOKEN}"
CHAT_ID="${USER_CHAT_ID}"

CPU_THRESHOLD=${USER_CPU}
RAM_THRESHOLD=${USER_RAM}
DISK_THRESHOLD=${USER_DISK}
ALERT_COOLDOWN=3600
SEND_RESOLVE_ALERT=true
EOF

chmod 600 "${CONFIG_DIR}/uptimka.conf"

curl -sSL "https://raw.githubusercontent.com/nixlife-lab/uptimka/main/uptimka.sh" -o "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"

CRON_JOB="*/${USER_INTERVAL} * * * * ${INSTALL_DIR}/${SCRIPT_NAME} --cron > /dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v "${SCRIPT_NAME}" ; echo "$CRON_JOB") | crontab -

echo ""
echo "==============================================="
echo "🎉 Установка завершена успешно!"
echo "📁 Конфиг: ${CONFIG_DIR}/uptimka.conf"
echo "⚙️ Скрипт: ${INSTALL_DIR}/${SCRIPT_NAME}"
echo "⏱ Проверка каждые ${USER_INTERVAL} мин через Cron"
echo "==============================================="
