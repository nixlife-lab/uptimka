#!/usr/bin/env bash
# Установщик uptimka — https://github.com/nixlife-lab/uptimka
#   Установка:  curl -sSL https://raw.githubusercontent.com/nixlife-lab/uptimka/main/install.sh | sudo bash
#   Удаление:   curl -sSL https://raw.githubusercontent.com/nixlife-lab/uptimka/main/install.sh | sudo bash -s -- --uninstall

set -eo pipefail

UPTIMKA_REF="${UPTIMKA_REF:-v1.2.0}"   # какую версию ставить (тег релиза; UPTIMKA_REF=main — самая свежая)
REPO_RAW="https://raw.githubusercontent.com/nixlife-lab/uptimka/${UPTIMKA_REF}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/uptimka"
CONFIG_FILE="${CONFIG_DIR}/uptimka.conf"
SCRIPT_NAME="uptimka"
STATE_DIR="/var/lib/uptimka"

ok()   { echo "✅ $*"; }
info() { echo "ℹ️  $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

ask() {   # ask "вопрос" значение_по_умолчанию → ответ в REPLY
    local prompt=$1 def=${2:-}
    if [ -n "$def" ]; then
        read -rp "${prompt} [${def}]: " REPLY < /dev/tty || true
        REPLY=${REPLY:-$def}
    else
        read -rp "${prompt}: " REPLY < /dev/tty || true
    fi
}

ask_number() {   # ask_number "вопрос" по_умолчанию мин макс
    local prompt=$1 def=$2 min=$3 max=$4
    while true; do
        ask "$prompt" "$def"
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge "$min" ] && [ "$REPLY" -le "$max" ]; then
            return 0
        fi
        warn "Нужно целое число от ${min} до ${max}"
    done
}

ask_yes() {   # ask_yes "вопрос" → 0, если да (по умолчанию — да)
    ask "$1 [Y/n]" ""
    case "$REPLY" in n|N|н|Н|no|нет) return 1 ;; *) return 0 ;; esac
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

remove_schedules() {   # убрать старые задания uptimka и nix-monitor из cron и systemd
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vE '/(uptimka|nix-monitor)( |$)' | crontab - 2>/dev/null || true
    fi
    if has_systemd && [ -f /etc/systemd/system/uptimka.timer ]; then
        systemctl disable --now uptimka.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/uptimka.timer /etc/systemd/system/uptimka.service
        systemctl daemon-reload
    fi
}

uninstall() {
    echo "🗑  Удаление uptimka"
    remove_schedules
    rm -f "${INSTALL_DIR}/${SCRIPT_NAME}" /run/lock/uptimka.lock
    rm -rf "$STATE_DIR"
    if [ -d "$CONFIG_DIR" ]; then
        if ask_yes "Удалить и конфиг ${CONFIG_FILE} (токен бота, пороги)?"; then
            rm -rf "$CONFIG_DIR"
        else
            info "Конфиг оставлен: ${CONFIG_FILE}"
        fi
    fi
    ok "uptimka удалён"
    exit 0
}

# ==========================================================
# Проверки
# ==========================================================
[ "$EUID" -eq 0 ] || die "Запустите установщик с правами root (через sudo)."
[ "${1:-}" = "--uninstall" ] && uninstall

for cmd in curl awk ps df; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена команда «${cmd}». Установите её и запустите снова."
done

if ! has_systemd && ! command -v crontab >/dev/null 2>&1; then
    die "Нет ни systemd, ни cron — нечем запускать проверки. Установите cron (apt install cron) и повторите."
fi

echo "==============================================="
echo "   🐧 Установка uptimka (${UPTIMKA_REF})"
echo "==============================================="
echo ""

# ==========================================================
# Переход с nix-monitor (старое имя проекта)
# ==========================================================
OLD_CONF="/etc/nix-monitor/nix-monitor.conf"
if [ -f "${INSTALL_DIR}/nix-monitor" ] || [ -f "$OLD_CONF" ]; then
    info "Найдена старая версия под именем nix-monitor."
    if [ -f "$OLD_CONF" ] && [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$CONFIG_DIR"
        cp "$OLD_CONF" "$CONFIG_FILE"
        ok "Настройки перенесены из ${OLD_CONF}"
    fi
    remove_schedules
    rm -f "${INSTALL_DIR}/nix-monitor" /var/run/nix-monitor.state
    rm -rf /etc/nix-monitor
    ok "nix-monitor удалён, дальше работает uptimka"
    echo ""
fi

# ==========================================================
# Настройки
# ==========================================================
KEEP_CONFIG=false
if [ -f "$CONFIG_FILE" ]; then
    if ask_yes "Найден конфиг ${CONFIG_FILE}. Оставить текущие настройки?"; then
        KEEP_CONFIG=true
    fi
fi

if [ "$KEEP_CONFIG" = false ]; then
    while true; do
        read -rsp "Telegram Bot Token (ввод скрыт): " USER_TOKEN < /dev/tty || true
        echo ""
        [[ "$USER_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] && break
        warn "Не похоже на токен. Он выглядит так: 123456789:AAH... — его выдаёт @BotFather"
    done
    while true; do
        ask "Telegram Chat ID (число, для групп — с минусом, или @канал)" ""
        USER_CHAT_ID=$REPLY
        [[ "$USER_CHAT_ID" =~ ^-?[0-9]+$|^@[A-Za-z0-9_]{5,}$ ]] && break
        warn "Chat ID — это число (например 987654321 или -1001234567890) либо @имя_канала"
    done

    ask_number "Порог CPU, %" 85 1 100;  USER_CPU=$REPLY
    ask_number "Порог RAM, %" 90 1 100;  USER_RAM=$REPLY
    ask_number "Порог заполнения диска, %" 90 1 100; USER_DISK=$REPLY
    ask "Какие диски проверять (точки монтирования через пробел)" "/"
    USER_DISKS=$REPLY
fi

ask_number "Интервал проверки, минут" 5 1 59; USER_INTERVAL=$REPLY

# Регулярный отчёт о состоянии сервера (алерты о проблемах приходят независимо от него)
echo ""
echo "📊 Регулярный отчёт о состоянии сервера в Telegram:"
echo "   0 — не присылать   1 — каждый час   2 — каждый день   3 — раз в неделю"
ask_number "Ваш выбор" 2 0 3
USER_REPORT_TIME="09:00"; USER_REPORT_DAY=1
case "$REPLY" in
    0) USER_REPORT="off" ;;
    1) USER_REPORT="hourly" ;;
    2) USER_REPORT="daily" ;;
    3) USER_REPORT="weekly"
       ask_number "День недели (1 — пн … 7 — вс)" 1 1 7; USER_REPORT_DAY=$REPLY ;;
esac
if [ "$USER_REPORT" = "daily" ] || [ "$USER_REPORT" = "weekly" ]; then
    while true; do
        ask "Во сколько присылать (ЧЧ:ММ, время сервера — сейчас $(date +%H:%M))" "09:00"
        [[ "$REPLY" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]] && break
        warn "Время в формате ЧЧ:ММ, например 09:00"
    done
    USER_REPORT_TIME=$REPLY
fi

# ==========================================================
# Проверка Telegram
# ==========================================================
if [ "$KEEP_CONFIG" = false ]; then
    echo ""
    echo "⏳ Проверяю связь с Telegram..."
    TEST_MSG="✅ <b>uptimka установлен!</b>
💻 Хост: <code>$(hostname)</code>
Уведомления будут приходить сюда 👍"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        -X POST "https://api.telegram.org/bot${USER_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${USER_CHAT_ID}" \
        --data-urlencode "text=${TEST_MSG}" \
        -d "parse_mode=HTML" || true)

    if [ "$HTTP_STATUS" != "200" ]; then
        echo "❌ Тестовое сообщение не отправилось (HTTP ${HTTP_STATUS:-нет ответа})."
        case "$HTTP_STATUS" in
            401|404) echo "   Неверный Bot Token." ;;
            400|403) echo "   Неверный Chat ID, или вы не написали боту /start (в группе — бот не добавлен)." ;;
            000|"")  echo "   Нет связи с api.telegram.org — проверьте интернет/фаервол сервера." ;;
        esac
        exit 1
    fi
    ok "Тестовое сообщение доставлено в Telegram"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Конфигурация uptimka — https://github.com/nixlife-lab/uptimka
# После правки ничего перезапускать не нужно: настройки читаются при каждой проверке.

# Telegram
BOT_TOKEN="${USER_TOKEN}"
CHAT_ID="${USER_CHAT_ID}"

# Пороги алертов, %
CPU_THRESHOLD=${USER_CPU}
RAM_THRESHOLD=${USER_RAM}
DISK_THRESHOLD=${USER_DISK}

# Точки монтирования для проверки, через пробел (например "/ /mnt/data")
DISKS="${USER_DISKS}"

# Повторный алерт при затянувшейся проблеме — не чаще, чем раз в N секунд (3600 = 1 час)
ALERT_COOLDOWN=3600

# Сообщать, когда всё вернулось в норму
SEND_RESOLVE_ALERT=true

# Сообщать о перезагрузке сервера
NOTIFY_REBOOT=true

# Docker-контейнеры, которые не нужно проверять (имена через пробел)
DOCKER_IGNORE=""
EOF
fi

# Настройки отчёта: заменяем строки в конфиге, а если их нет (старый конфиг) — дописываем
set_conf() {   # set_conf КЛЮЧ значение
    if grep -q "^${1}=" "$CONFIG_FILE"; then
        sed -i "s|^${1}=.*|${1}=${2}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$1" "$2" >> "$CONFIG_FILE"
    fi
}
if ! grep -q '^REPORT=' "$CONFIG_FILE"; then
    printf '\n# Регулярный отчёт: off / hourly / daily / weekly; время — по часам сервера; день: 1 — пн … 7 — вс\n' >> "$CONFIG_FILE"
fi
set_conf REPORT "\"${USER_REPORT}\""
set_conf REPORT_TIME "\"${USER_REPORT_TIME}\""
set_conf REPORT_DAY "${USER_REPORT_DAY}"
chmod 600 "$CONFIG_FILE"

# ==========================================================
# Установка скрипта
# ==========================================================
TMP_SCRIPT=$(mktemp)
trap 'rm -f "$TMP_SCRIPT"' EXIT

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$SRC_DIR" ] && [ -f "${SRC_DIR}/uptimka.sh" ] && [ "${BASH_SOURCE[0]:-}" != "" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    info "Ставлю uptimka.sh из локальной папки ${SRC_DIR}"
    cp "${SRC_DIR}/uptimka.sh" "$TMP_SCRIPT"
else
    if ! curl -fsSL --max-time 30 "${REPO_RAW}/uptimka.sh" -o "$TMP_SCRIPT" 2>/dev/null; then
        [ "$UPTIMKA_REF" = "main" ] && die "Не удалось скачать ${REPO_RAW}/uptimka.sh"
        warn "Версия ${UPTIMKA_REF} не найдена, ставлю последнюю из ветки main"
        REPO_RAW="https://raw.githubusercontent.com/nixlife-lab/uptimka/main"
        curl -fsSL --max-time 30 "${REPO_RAW}/uptimka.sh" -o "$TMP_SCRIPT" \
            || die "Не удалось скачать ${REPO_RAW}/uptimka.sh"
    fi
fi

# Проверяем, что скачался именно скрипт, а не страница ошибки
# shellcheck disable=SC2015
head -n 1 "$TMP_SCRIPT" | grep -q '^#!/usr/bin/env bash' && bash -n "$TMP_SCRIPT" \
    || die "Скачанный файл повреждён — попробуйте ещё раз"

install -m 755 "$TMP_SCRIPT" "${INSTALL_DIR}/${SCRIPT_NAME}"
mkdir -p "$STATE_DIR"
ok "Скрипт установлен: ${INSTALL_DIR}/${SCRIPT_NAME} ($("${INSTALL_DIR}/${SCRIPT_NAME}" --version))"

# ==========================================================
# Расписание: systemd-таймер, если есть systemd, иначе cron
# ==========================================================
remove_schedules

if has_systemd; then
    cat > /etc/systemd/system/uptimka.service <<EOF
[Unit]
Description=uptimka — проверка сервера
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/${SCRIPT_NAME} --cron
EOF
    cat > /etc/systemd/system/uptimka.timer <<EOF
[Unit]
Description=uptimka — проверка каждые ${USER_INTERVAL} мин

[Timer]
OnBootSec=1min
OnUnitActiveSec=${USER_INTERVAL}min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now uptimka.timer >/dev/null
    SCHEDULE="systemd-таймер uptimka.timer (systemctl list-timers uptimka)"
else
    CRON_JOB="*/${USER_INTERVAL} * * * * ${INSTALL_DIR}/${SCRIPT_NAME} --cron > /dev/null 2>&1"
    (crontab -l 2>/dev/null || true; echo "$CRON_JOB") | crontab -
    SCHEDULE="cron (crontab -l)"
fi

echo ""
echo "==============================================="
echo "🎉 Готово!"
echo "📁 Конфиг:     ${CONFIG_FILE}"
echo "⚙️  Скрипт:     ${INSTALL_DIR}/${SCRIPT_NAME}"
echo "⏱  Проверка:   каждые ${USER_INTERVAL} мин — ${SCHEDULE}"
echo ""
echo "👉 Попробуйте:  uptimka        — дашборд"
echo "                uptimka -w     — живой режим"
echo "                uptimka --help — все команды"
echo "==============================================="
