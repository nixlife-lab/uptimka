#!/usr/bin/env bash

set -eo pipefail

CONFIG_FILE="/etc/nix-monitor/nix-monitor.conf"
STATE_FILE="/var/run/nix-monitor.state"

# ANSI-цвета
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_BLUE="\033[1;34m"
C_CYAN="\033[36m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_GRAY="\033[90m"

# Чтение конфига
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    CPU_THRESHOLD=85
    RAM_THRESHOLD=90
    DISK_THRESHOLD=90
    ALERT_COOLDOWN=3600
    SEND_RESOLVE_ALERT=true
fi

HOSTNAME=$(hostname)
CURRENT_TIME=$(date +%s)
UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")

# ==========================================================
# 1. Сбор системных метрик
# ==========================================================

# RAM
RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_USAGE=$(awk "BEGIN {printf \"%.0f\", ($RAM_USED/$RAM_TOTAL)*100}")

# Диск (корень /)
DISK_USAGE=$(df -h / | awk 'NR==2 {sub(/%/, ""); print $5}')
DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')

# CPU за 1 секунду
CPU_USAGE=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else print int(($2+$4-u1) * 100 / (t-t1))}' \
  <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

# Температура CPU (sysfs)
CPU_TEMP="N/A"
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    RAW_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
    if [ "$RAW_TEMP" -gt 0 ]; then
        CPU_TEMP="$(( RAW_TEMP / 1000 ))°C"
    fi
fi

LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ //')

# ==========================================================
# 2. Проверка Docker и аварийных контейнеров
# ==========================================================
DOCKER_AVAILABLE=false
FAILED_CONTAINERS=()
DOCKER_SUMMARY="Не установлен"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_AVAILABLE=true
    DOCKER_RUNNING=$(docker ps -q | wc -l | tr -d ' ')
    DOCKER_TOTAL=$(docker ps -a -q | wc -l | tr -d ' ')
    DOCKER_SUMMARY="${DOCKER_RUNNING} активен / ${DOCKER_TOTAL} всего"

    # Ищем контейнеры со статусом Exited, код выхода которых НЕ равен 0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            FAILED_CONTAINERS+=("$line")
        fi
    done < <(docker ps -a --filter "status=exited" --format '{{.Names}} (Exit {{.State}})' | grep -v '(Exit exited (0))' || true)
fi

# ==========================================================
# 3. CLI Прогресс-бар и Отрисовка Дашборда
# ==========================================================
draw_bar() {
    local val=$1
    local threshold=$2
    local width=20
    local filled=$(( (val * width) / 100 ))
    local empty=$(( width - filled ))
    
    local color="$C_GREEN"
    if [ "$val" -ge "$threshold" ]; then
        color="$C_RED"
    elif [ "$val" -ge 70 ]; then
        color="$C_YELLOW"
    fi

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="■"; done
    local bar_empty=""
    for ((i=0; i<empty; i++)); do bar_empty+="·"; done

    printf "%b[%s%b%s%b] %3d%%%b" "$color" "$bar" "$C_GRAY" "$bar_empty" "$color" "$val" "$C_RESET"
}

render_dashboard() {
    clear
    echo -e "${C_BLUE}┌────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_BLUE}│${C_BOLD}${C_CYAN}  🐧 nix-monitor :: Панель управления сервером        ${C_BLUE}│${C_RESET}"
    echo -e "${C_BLUE}├────────────────────────────────────────────────────────┤${C_RESET}"
    printf "${C_BLUE}│${C_RESET}  %-14s %-39s ${C_BLUE}│${C_RESET}\n" "🖥  Хост:" "${C_BOLD}${HOSTNAME}${C_RESET}"
    printf "${C_BLUE}│${C_RESET}  %-14s %-39s ${C_BLUE}│${C_RESET}\n" "⏱  Аптайм:" "${UPTIME_STR}"
    printf "${C_BLUE}│${C_RESET}  %-14s %-39s ${C_BLUE}│${C_RESET}\n" "🌡  Темп. CPU:" "${CPU_TEMP}  ${C_GRAY}(Load: ${LOAD_AVG})${C_RESET}"
    
    if [ "${#FAILED_CONTAINERS[@]}" -gt 0 ]; then
        printf "${C_BLUE}│${C_RESET}  %-14s %-39b ${C_BLUE}│${C_RESET}\n" "🐳 Docker:" "${C_RED}${DOCKER_SUMMARY} (${#FAILED_CONTAINERS[@]} краш!)${C_RESET}"
    else
        printf "${C_BLUE}│${C_RESET}  %-14s %-39s ${C_BLUE}│${C_RESET}\n" "🐳 Docker:" "${DOCKER_SUMMARY}"
    fi

    echo -e "${C_BLUE}├────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_BLUE}│${C_BOLD}  РЕСУРСЫ СИСТЕМЫ                                       ${C_BLUE}│${C_RESET}"
    
    printf "${C_BLUE}│${C_RESET}  CPU:  "
    draw_bar "$CPU_USAGE" "$CPU_THRESHOLD"
    printf "   ${C_GRAY}(Порог: %d%%)${C_RESET}       ${C_BLUE}│${C_RESET}\n" "$CPU_THRESHOLD"

    printf "${C_BLUE}│${C_RESET}  RAM:  "
    draw_bar "$RAM_USAGE" "$RAM_THRESHOLD"
    printf "   ${C_GRAY}%sM/%sM${C_RESET}   ${C_BLUE}│${C_RESET}\n" "$RAM_USED" "$RAM_TOTAL"

    printf "${C_BLUE}│${C_RESET}  ДИСК: "
    draw_bar "$DISK_USAGE" "$DISK_THRESHOLD"
    printf "   ${C_GRAY}Своб: %s (%s)${C_RESET}    ${C_BLUE}│${C_RESET}\n" "$DISK_FREE" "$DISK_TOTAL"

    if [ "${#FAILED_CONTAINERS[@]}" -gt 0 ]; then
        echo -e "${C_BLUE}├────────────────────────────────────────────────────────┤${C_RESET}"
        echo -e "${C_BLUE}│${C_BOLD}${C_RED}  ⚠️ УПАВШИЕ DOCKER-КОНТЕЙНЕРЫ                          ${C_BLUE}│${C_RESET}"
        for failed in "${FAILED_CONTAINERS[@]}"; do
            printf "${C_BLUE}│${C_RESET}  ${C_RED}✖ %-51s${C_RESET} ${C_BLUE}│${C_RESET}\n" "${failed:0:51}"
        done
    fi

    echo -e "${C_BLUE}├────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_BLUE}│${C_BOLD}  ТОП-3 ПРОЦЕССОВ (RAM / CPU)                           ${C_BLUE}│${C_RESET}"
    
    ps -eo comm,%mem,%cpu --sort=-%mem | head -n 4 | tail -n 3 | while read -r comm mem cpu; do
        printf "${C_BLUE}│${C_RESET}  • %-18s %6s%% RAM  %6s%% CPU            ${C_BLUE}│${C_RESET}\n" "${comm:0:18}" "$mem" "$cpu"
    done

    echo -e "${C_BLUE}└────────────────────────────────────────────────────────┘${C_RESET}"
}

# Режимы терминала
if [ "$1" = "-w" ] || [ "$1" = "--watch" ]; then
    while true; do
        render_dashboard
        sleep 2
    done
elif [ -t 1 ] && [ "$1" != "--cron" ]; then
    render_dashboard
    exit 0
fi

# ==========================================================
# 4. Фоновая аналитика инцидентов (Cron)
# ==========================================================
ALERT_REASONS=()

if [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ]; then
    ALERT_REASONS+=("🔴 <b>CPU:</b> <code>${CPU_USAGE}%</code> (Порог: ${CPU_THRESHOLD}%)")
fi

if [ "$RAM_USAGE" -ge "$RAM_THRESHOLD" ]; then
    ALERT_REASONS+=("🔴 <b>RAM:</b> <code>${RAM_USAGE}%</code> (Порог: ${RAM_THRESHOLD}%)")
fi

if [ "$DISK_USAGE" -ge "$DISK_THRESHOLD" ]; then
    ALERT_REASONS+=("🔴 <b>Диск (/):</b> <code>${DISK_USAGE}%</code> (Порог: ${DISK_THRESHOLD}%)")
fi

if [ "${#FAILED_CONTAINERS[@]}" -gt 0 ]; then
    DOCKER_ALERT_TEXT="💥 <b>Docker: обнаружены упавшие контейнеры!</b>%0A"
    for failed in "${FAILED_CONTAINERS[@]}"; do
        DOCKER_ALERT_TEXT+="  ✖ <code>${failed}</code>%0A"
    done
    ALERT_REASONS+=("${DOCKER_ALERT_TEXT}")
fi

PREV_STATUS="OK"
LAST_ALERT_TIME=0
FIRST_INCIDENT_TIME=0

if [ -f "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
fi

send_telegram() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "text=${text}" \
        -d "parse_mode=HTML" > /dev/null 2>&1 || true
}

# ==========================================================
# 5. Обработка Cooldown и Resolve
# ==========================================================

if [ "${#ALERT_REASONS[@]}" -gt 0 ]; then
    TIME_SINCE_LAST_ALERT=$((CURRENT_TIME - LAST_ALERT_TIME))

    if [ "$PREV_STATUS" = "OK" ] || [ "$TIME_SINCE_LAST_ALERT" -ge "$ALERT_COOLDOWN" ]; then
        if [ "$PREV_STATUS" = "OK" ]; then
            FIRST_INCIDENT_TIME=$CURRENT_TIME
            TITLE="🚨 <b>[ALERT] Инцидент на сервере!</b>"
        else
            TITLE="🔔 <b>[ALERT] Инцидент сохраняется (повтор)</b>"
        fi

        MSG="${TITLE}%0A"
        MSG+="🖥 <b>Хост:</b> <code>${HOSTNAME}</code>%0A"
        MSG+="⏱ <b>Uptime:</b> <code>${UPTIME_STR}</code>%0A%0A"
        
        for reason in "${ALERT_REASONS[@]}"; do
            MSG+="${reason}%0A"
        done

        MSG+="%0A<b>Топ процессов по RAM:</b>%0A"
        TOP_LIST=$(ps -eo pid,comm,%mem,%cpu --sort=-%mem | head -n 4 | tail -n 3 | awk '{printf "• %s (PID %s): %s%% RAM, %s%% CPU%%0A", $2, $1, $3, $4}')
        MSG+="${TOP_LIST}"

        send_telegram "$MSG"

        cat <<EOF > "$STATE_FILE"
PREV_STATUS="CRITICAL"
LAST_ALERT_TIME=${CURRENT_TIME}
FIRST_INCIDENT_TIME=${FIRST_INCIDENT_TIME}
EOF
    fi

elif [ "$PREV_STATUS" = "CRITICAL" ]; then
    if [ "$SEND_RESOLVE_ALERT" = true ]; then
        DURATION=$(( (CURRENT_TIME - FIRST_INCIDENT_TIME) / 60 ))
        [ "$DURATION" -eq 0 ] && DURATION=1

        MSG="✅ <b>[RESOLVED] Работа сервера стабилизирована!</b>%0A"
        MSG+="🖥 <b>Хост:</b> <code>${HOSTNAME}</code>%0A"
        MSG+="⏳ <b>Длительность сбоя:</b> ~${DURATION} мин.%0A%0A"
        MSG+="📊 <b>Текущие показатели:</b>%0A"
        MSG+="• CPU: <code>${CPU_USAGE}%</code>%0A"
        MSG+="• RAM: <code>${RAM_USAGE}%</code>%0A"
        MSG+="• Диск: <code>${DISK_USAGE}%</code>%0A"
        if [ "$DOCKER_AVAILABLE" = true ]; then
            MSG+="• Docker: <code>Все контейнеры в строю (${DOCKER_RUNNING}/${DOCKER_TOTAL})</code>"
        fi

        send_telegram "$MSG"
    fi

    cat <<EOF > "$STATE_FILE"
PREV_STATUS="OK"
LAST_ALERT_TIME=0
FIRST_INCIDENT_TIME=0
EOF
fi
