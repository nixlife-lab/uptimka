#!/usr/bin/env bash
# uptimka — лёгкий мониторинг сервера на чистом Bash: TUI-дашборд + алерты в Telegram
# https://github.com/nixlife-lab/uptimka · MIT

set -o pipefail

UPTIMKA_VERSION="1.1.0"

# cron запускает задачи с урезанным PATH — добавляем стандартные пути (и snap, где бывает Docker)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:${PATH}"

CONFIG_FILE="${UPTIMKA_CONFIG:-/etc/uptimka/uptimka.conf}"
STATE_DIR="/var/lib/uptimka"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="/run/lock/uptimka.lock"

# ==========================================================
# Цвета (отключаются через NO_COLOR=1 или если вывод не в терминал)
# ==========================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[1;31m'; C_GRAY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_BLUE=""; C_CYAN=""
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi

# ==========================================================
# Конфиг: значения по умолчанию → файл → проверка
# ==========================================================
BOT_TOKEN=""
CHAT_ID=""
CPU_THRESHOLD=85
RAM_THRESHOLD=90
DISK_THRESHOLD=90
DISKS="/"
ALERT_COOLDOWN=3600
SEND_RESOLVE_ALERT=true
NOTIFY_REBOOT=true
DOCKER_IGNORE=""

if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_pct() { is_int "$1" && [ "$1" -ge 1 ] && [ "$1" -le 100 ]; }

CONFIG_WARNINGS=()
check_pct() {   # check_pct ИМЯ_ПЕРЕМЕННОЙ значение_по_умолчанию
    local name=$1 def=$2
    if ! is_pct "${!name}"; then
        CONFIG_WARNINGS+=("${name}=\"${!name}\" — не число 1–100, взято ${def}")
        printf -v "$name" '%s' "$def"
    fi
}
check_pct CPU_THRESHOLD 85
check_pct RAM_THRESHOLD 90
check_pct DISK_THRESHOLD 90
if ! is_int "$ALERT_COOLDOWN"; then
    CONFIG_WARNINGS+=("ALERT_COOLDOWN=\"${ALERT_COOLDOWN}\" — не число, взято 3600")
    ALERT_COOLDOWN=3600
fi
[ -z "$DISKS" ] && DISKS="/"

# ==========================================================
# Вспомогательные функции
# ==========================================================

# Экранирование для parse_mode=HTML в Telegram: без него «<», «>» и «&» ломают всё сообщение
html_escape() {
    # Замены в кавычках: в bash 5.2 голый «&» в замене означает найденный текст
    local s=$1 amp='&amp;' lt='&lt;' gt='&gt;'
    s=${s//&/"$amp"}
    s=${s//</"$lt"}
    s=${s//>/"$gt"}
    printf '%s' "$s"
}

# «3 дн. 4 ч. 12 мин.» из /proc/uptime (не зависит от локали и версии uptime)
format_duration() {
    local sec=$1 d h m out=""
    d=$(( sec / 86400 )); h=$(( sec % 86400 / 3600 )); m=$(( sec % 3600 / 60 ))
    [ "$d" -gt 0 ] && out+="${d} дн. "
    [ "$h" -gt 0 ] && out+="${h} ч. "
    out+="${m} мин."
    printf '%s' "$out"
}

in_list() {     # in_list слово "список через пробел"
    local item
    for item in $2; do [ "$item" = "$1" ] && return 0; done
    return 1
}

# ==========================================================
# 1. Сбор метрик — вызывается заново на каждом обновлении
# ==========================================================
read_cpu_times() {
    # Сумма всех полей cpu (user nice system idle iowait irq softirq steal) и «простой» = idle + iowait
    awk '/^cpu / { t=0; for (i=2; i<=9; i++) t+=$i; print t, $5+$6; exit }' /proc/stat
}

collect_metrics() {
    HOST_NAME=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
    CURRENT_TIME=$(date +%s)

    # --- Аптайм и загрузка
    local up_sec
    up_sec=$(awk '{print int($1)}' /proc/uptime)
    UPTIME_STR=$(format_duration "$up_sec")
    read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
    CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)

    # --- CPU: два замера с интервалом 1 с, учитываются все поля, включая iowait и steal
    local t1 i1 t2 i2 dt
    read -r t1 i1 < <(read_cpu_times)
    sleep 1
    read -r t2 i2 < <(read_cpu_times)
    dt=$(( t2 - t1 ))
    if [ "$dt" -gt 0 ]; then
        CPU_USAGE=$(( ( (dt - (i2 - i1)) * 100 + dt / 2 ) / dt ))
    else
        CPU_USAGE=0
    fi
    [ "$CPU_USAGE" -lt 0 ] && CPU_USAGE=0
    [ "$CPU_USAGE" -gt 100 ] && CPU_USAGE=100

    # --- RAM и swap напрямую из /proc/meminfo (free переводится и на ru-локали пишет «Память:»)
    local mem_total mem_avail swap_total swap_free
    read -r mem_total mem_avail swap_total swap_free < <(awk '
        /^MemTotal:/ {mt=$2} /^MemAvailable:/ {ma=$2}
        /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2}
        END {print mt+0, ma+0, st+0, sf+0}' /proc/meminfo)
    RAM_TOTAL=$(( mem_total / 1024 ))
    RAM_USED=$(( (mem_total - mem_avail) / 1024 ))
    if [ "$mem_total" -gt 0 ]; then
        RAM_USAGE=$(( ( (mem_total - mem_avail) * 100 + mem_total / 2 ) / mem_total ))
    else
        RAM_USAGE=0
    fi
    SWAP_TOTAL=$(( swap_total / 1024 ))
    SWAP_USED=$(( (swap_total - swap_free) / 1024 ))

    # --- Диски из списка DISKS (по умолчанию только /)
    DISK_MOUNTS=(); DISK_USAGES=(); DISK_FREES=(); DISK_SIZES=(); DISK_MISSING=()
    local mp line size avail pct
    for mp in $DISKS; do
        if ! line=$(LC_ALL=C df -P -h "$mp" 2>/dev/null | awk 'NR==2 {sub(/%/, "", $5); print $2, $4, $5}') \
           || [ -z "$line" ]; then
            DISK_MISSING+=("$mp")
            continue
        fi
        read -r size avail pct <<< "$line"
        DISK_MOUNTS+=("$mp"); DISK_SIZES+=("$size"); DISK_FREES+=("$avail"); DISK_USAGES+=("$pct")
    done

    # --- Температура CPU: ищем именно процессорный датчик, а не первый попавшийся (acpitz = плата)
    CPU_TEMP=""
    local hw name f zone type
    for hw in /sys/class/hwmon/hwmon*; do
        [ -r "$hw/name" ] || continue
        read -r name < "$hw/name"
        case "$name" in
            coretemp|k10temp|zenpower|cpu_thermal|soc_thermal|cpu-thermal)
                for f in "$hw/temp1_input" "$hw"/temp*_input; do
                    if [ -r "$f" ]; then
                        CPU_TEMP=$(( $(cat "$f") / 1000 ))
                        break 2
                    fi
                done
                ;;
        esac
    done
    if [ -z "$CPU_TEMP" ]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/type" ] || continue
            read -r type < "$zone/type"
            case "$type" in
                x86_pkg_temp|cpu*|soc*|CPU*)
                    CPU_TEMP=$(( $(cat "$zone/temp" 2>/dev/null || echo 0) / 1000 ))
                    [ "$CPU_TEMP" -gt 0 ] && break
                    CPU_TEMP=""
                    ;;
            esac
        done
    fi

    collect_docker
}

# ==========================================================
# 2. Docker: упавшие, OOM, unhealthy и перезапускающиеся по кругу
# ==========================================================
collect_docker() {
    DOCKER_AVAILABLE=false
    DOCKER_PROBLEMS=()
    DOCKER_RUNNING=0
    DOCKER_TOTAL=0

    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    DOCKER_AVAILABLE=true

    local ids
    ids=$(docker ps -aq 2>/dev/null)
    [ -z "$ids" ] && return 0

    local name status code oom health
    # shellcheck disable=SC2086
    while IFS='|' read -r name status code oom health; do
        [ -z "$name" ] && continue
        name=${name#/}
        DOCKER_TOTAL=$(( DOCKER_TOTAL + 1 ))
        [ "$status" = "running" ] && DOCKER_RUNNING=$(( DOCKER_RUNNING + 1 ))
        in_list "$name" "$DOCKER_IGNORE" && continue

        case "$status" in
            running)
                [ "$health" = "unhealthy" ] && DOCKER_PROBLEMS+=("${name}|нездоров (healthcheck)")
                ;;
            restarting)
                DOCKER_PROBLEMS+=("${name}|перезапускается по кругу")
                ;;
            dead)
                DOCKER_PROBLEMS+=("${name}|dead")
                ;;
            exited)
                if [ "$oom" = "true" ]; then
                    DOCKER_PROBLEMS+=("${name}|убит из-за нехватки памяти (OOM)")
                elif [ "$code" = "0" ] || [ "$code" = "143" ] || [ "$code" = "137" ]; then
                    # 0 — штатное завершение; 143/137 — SIGTERM/SIGKILL от docker stop, т.е. остановлен вручную
                    :
                else
                    DOCKER_PROBLEMS+=("${name}|упал, код выхода ${code}")
                fi
                ;;
        esac
    done < <(docker inspect --format \
        '{{.Name}}|{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        $ids 2>/dev/null)
}

# ==========================================================
# 3. TUI-дашборд (без правой рамки — ширину эмодзи терминалы считают по-разному)
# ==========================================================
level_color() {   # level_color значение порог → зелёный / жёлтый (≥80% порога) / красный
    local val=$1 thr=$2
    if [ "$val" -ge "$thr" ]; then printf '%s' "$C_RED"
    elif [ "$(( val * 100 ))" -ge "$(( thr * 80 ))" ]; then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_GREEN"; fi
}

draw_bar() {
    local val=$1 thr=$2 width=24 filled empty color bar="" rest="" i
    filled=$(( (val * width + 50) / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    empty=$(( width - filled ))
    color=$(level_color "$val" "$thr")
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do rest+="░"; done
    printf '%s%s%s%s%s %s%3d%%%s' "$color" "$bar" "$C_GRAY" "$rest" "$C_RESET" "$color$C_BOLD" "$val" "$C_RESET"
}

LINE="${C_BLUE}│${C_RESET}"
section() { printf '%s\n' "${C_BLUE}├─${C_RESET} ${C_BOLD}$1${C_RESET}"; }
row()     { printf '%s %s\n' "$LINE" "$1"; }

render_dashboard() {
    local problems=0 i mp color
    [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ] && problems=$(( problems + 1 ))
    [ "$RAM_USAGE" -ge "$RAM_THRESHOLD" ] && problems=$(( problems + 1 ))
    for i in "${!DISK_USAGES[@]}"; do
        [ "${DISK_USAGES[$i]}" -ge "$DISK_THRESHOLD" ] && problems=$(( problems + 1 ))
    done
    problems=$(( problems + ${#DOCKER_PROBLEMS[@]} ))

    local status
    if [ "$problems" -eq 0 ]; then
        status="${C_GREEN}${C_BOLD}✅ Всё в норме${C_RESET}"
    else
        status="${C_RED}🚨 Проблем: ${problems}${C_RESET}"
    fi

    printf '%s\n' "${C_BLUE}╭─────────────────────────────────────────────────────${C_RESET}"
    printf '%s %s  %s\n' "$LINE" "🐧 ${C_CYAN}uptimka${C_RESET} ${C_GRAY}v${UPTIMKA_VERSION}${C_RESET}" "$status"
    printf '%s %s\n' "$LINE" "${C_GRAY}$(date '+%d.%m.%Y %H:%M:%S')${C_RESET}"

    section "📋 Система"
    row "💻 Хост      ${C_BOLD}${HOST_NAME}${C_RESET}"
    row "⏰ Аптайм    ${UPTIME_STR}"
    if [ -n "$CPU_TEMP" ]; then
        if [ "$CPU_TEMP" -ge 80 ]; then color=$C_RED
        elif [ "$CPU_TEMP" -ge 65 ]; then color=$C_YELLOW
        else color=$C_GREEN; fi
        row "🔥 Темп. CPU ${color}${CPU_TEMP}°C${C_RESET}"
    else
        row "🔥 Темп. CPU ${C_GRAY}нет датчика${C_RESET}"
    fi
    row "📈 Нагрузка  ${LOAD1}  ${LOAD5}  ${LOAD15}  ${C_GRAY}(ядер: ${CPU_CORES})${C_RESET}"

    section "📊 Ресурсы"
    row "⚡ CPU   $(draw_bar "$CPU_USAGE" "$CPU_THRESHOLD")  ${C_GRAY}порог ${CPU_THRESHOLD}%${C_RESET}"
    row "🧠 RAM   $(draw_bar "$RAM_USAGE" "$RAM_THRESHOLD")  ${C_GRAY}${RAM_USED} / ${RAM_TOTAL} МБ${C_RESET}"
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        row "   ${C_GRAY}swap  ${SWAP_USED} / ${SWAP_TOTAL} МБ${C_RESET}"
    fi
    for i in "${!DISK_MOUNTS[@]}"; do
        mp=${DISK_MOUNTS[$i]}
        row "💾 Диск  $(draw_bar "${DISK_USAGES[$i]}" "$DISK_THRESHOLD")  ${C_GRAY}свободно ${DISK_FREES[$i]} из ${DISK_SIZES[$i]} (${mp})${C_RESET}"
    done
    for mp in "${DISK_MISSING[@]}"; do
        row "💾 ${C_YELLOW}${mp} — не найден, проверьте DISKS в конфиге${C_RESET}"
    done

    section "🐳 Docker"
    if [ "$DOCKER_AVAILABLE" != true ]; then
        row "${C_GRAY}не установлен или недоступен${C_RESET}"
    else
        if [ "${#DOCKER_PROBLEMS[@]}" -eq 0 ]; then
            row "${C_GREEN}✔${C_RESET} Работает ${C_BOLD}${DOCKER_RUNNING}${C_RESET} из ${DOCKER_TOTAL} — проблем нет"
        else
            row "Работает ${C_BOLD}${DOCKER_RUNNING}${C_RESET} из ${DOCKER_TOTAL}"
            local p
            for p in "${DOCKER_PROBLEMS[@]}"; do
                row "${C_RED}💥 ${p%%|*}${C_RESET} ${C_GRAY}— ${p#*|}${C_RESET}"
            done
        fi
    fi

    section "🏆 Топ-3 по памяти"
    local comm mem cpu
    while read -r comm mem cpu; do
        row "$(printf '• %-16s %s%5s%%%s RAM  %s%5s%%%s CPU' "${comm:0:16}" "$C_BOLD" "$mem" "$C_RESET" "$C_BOLD" "$cpu" "$C_RESET")"
    done < <(ps -eo comm=,%mem=,%cpu= --sort=-%mem | head -n 3)

    if [ "${#CONFIG_WARNINGS[@]}" -gt 0 ]; then
        section "⚠️  Конфиг"
        local w
        for w in "${CONFIG_WARNINGS[@]}"; do row "${C_YELLOW}${w}${C_RESET}"; done
    fi

    printf '%s\n' "${C_BLUE}╰─────────────────────────────────────────────────────${C_RESET}"
}

# ==========================================================
# 4. Telegram
# ==========================================================
# Возвращает 0 только если Telegram ответил 200 — иначе статус не меняется и попытка повторится
send_telegram() {
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        echo "uptimka: BOT_TOKEN/CHAT_ID не заданы в ${CONFIG_FILE}" >&2
        return 1
    fi
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 2 --retry-delay 3 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=$1" \
        -d "parse_mode=HTML" -d "disable_web_page_preview=true" 2>/dev/null)
    if [ "$code" = "200" ]; then
        return 0
    fi
    echo "uptimka: Telegram ответил HTTP ${code:-000}" >&2
    return 1
}

top_processes_html() {
    ps -eo pid=,comm=,%mem=,%cpu= --sort=-%mem | head -n 3 | while read -r pid comm mem cpu; do
        printf '• %s (PID %s): %s%% RAM, %s%% CPU\n' "$(html_escape "$comm")" "$pid" "$mem" "$cpu"
    done
}

# ==========================================================
# 5. Состояние между запусками (/var/lib переживает перезагрузку, в отличие от /run)
# ==========================================================
PREV_STATUS="OK"
LAST_ALERT_TIME=0
FIRST_INCIDENT_TIME=0
LAST_REASONS=""
BOOT_ID=""

load_state() {
    [ -r "$STATE_FILE" ] || return 0
    # Читаем как «ключ=значение», а не через source — файл не выполняется как код
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            PREV_STATUS) PREV_STATUS=$value ;;
            LAST_ALERT_TIME) is_int "$value" && LAST_ALERT_TIME=$value ;;
            FIRST_INCIDENT_TIME) is_int "$value" && FIRST_INCIDENT_TIME=$value ;;
            LAST_REASONS) LAST_REASONS=$value ;;
            BOOT_ID) BOOT_ID=$value ;;
        esac
    done < "$STATE_FILE"
}

save_state() {   # save_state статус время_алерта время_начала ключ_причин
    mkdir -p "$STATE_DIR"
    local tmp="${STATE_FILE}.tmp"
    {
        echo "PREV_STATUS=$1"
        echo "LAST_ALERT_TIME=$2"
        echo "FIRST_INCIDENT_TIME=$3"
        echo "LAST_REASONS=$4"
        echo "BOOT_ID=${CURRENT_BOOT_ID}"
    } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# ==========================================================
# 6. Фоновая проверка (cron / systemd timer)
# ==========================================================
run_check() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "uptimka: режим --cron нужно запускать от root" >&2
        exit 1
    fi

    # Защита от наложения запусков
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")"
        exec 9> "$LOCK_FILE"
        flock -n 9 || exit 0
    fi

    collect_metrics
    load_state
    CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

    local host_html
    host_html=$(html_escape "$HOST_NAME")

    # --- Перезагрузка
    if [ "$NOTIFY_REBOOT" = true ] && [ -n "$BOOT_ID" ] && [ "$BOOT_ID" != "$CURRENT_BOOT_ID" ]; then
        local rmsg="🔄 <b>Сервер перезагрузился</b>
💻 <b>Хост:</b> <code>${host_html}</code>
⏰ <b>Работает:</b> ${UPTIME_STR}"
        send_telegram "$rmsg" || true
    fi

    # --- Причины тревоги (ключ — для отслеживания смены ситуации, текст — для сообщения)
    local keys=() lines=() i mp p name
    if [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ]; then
        keys+=("cpu"); lines+=("⚡ <b>CPU:</b> <code>${CPU_USAGE}%</code> (порог ${CPU_THRESHOLD}%)")
    fi
    if [ "$RAM_USAGE" -ge "$RAM_THRESHOLD" ]; then
        keys+=("ram"); lines+=("🧠 <b>RAM:</b> <code>${RAM_USAGE}%</code> — ${RAM_USED} из ${RAM_TOTAL} МБ (порог ${RAM_THRESHOLD}%)")
    fi
    for i in "${!DISK_MOUNTS[@]}"; do
        mp=${DISK_MOUNTS[$i]}
        if [ "${DISK_USAGES[$i]}" -ge "$DISK_THRESHOLD" ]; then
            keys+=("disk:${mp}")
            lines+=("💾 <b>Диск $(html_escape "$mp"):</b> <code>${DISK_USAGES[$i]}%</code>, свободно ${DISK_FREES[$i]} (порог ${DISK_THRESHOLD}%)")
        fi
    done
    for p in "${DOCKER_PROBLEMS[@]}"; do
        name=${p%%|*}
        keys+=("docker:${name}")
        lines+=("🐳 <b>Docker</b> <code>$(html_escape "$name")</code> — $(html_escape "${p#*|}")")
    done

    local reasons_key=""
    [ "${#keys[@]}" -gt 0 ] && reasons_key=$(printf '%s\n' "${keys[@]}" | sort | paste -sd, -)

    if [ "${#keys[@]}" -gt 0 ]; then
        local since=$(( CURRENT_TIME - LAST_ALERT_TIME ))
        local title="" first=$FIRST_INCIDENT_TIME

        if [ "$PREV_STATUS" != "CRITICAL" ]; then
            first=$CURRENT_TIME
            title="🚨 <b>Проблема на сервере!</b>"
        elif [ "$reasons_key" != "$LAST_REASONS" ]; then
            title="⚠️ <b>Ситуация изменилась</b>"
        elif [ "$since" -ge "$ALERT_COOLDOWN" ]; then
            title="🔔 <b>Проблема сохраняется</b> ($(format_duration $(( CURRENT_TIME - first ))))"
        fi

        if [ -n "$title" ]; then
            local msg line
            msg="${title}
💻 <b>Хост:</b> <code>${host_html}</code>
⏰ <b>Аптайм:</b> ${UPTIME_STR}
"
            for line in "${lines[@]}"; do msg+="
${line}"; done
            msg+="

🏆 <b>Топ процессов по памяти:</b>
$(top_processes_html)"

            # Не дошло — статус не меняем, на следующем запуске попробуем снова
            if send_telegram "$msg"; then
                save_state "CRITICAL" "$CURRENT_TIME" "$first" "$reasons_key"
            fi
        elif [ "$BOOT_ID" != "$CURRENT_BOOT_ID" ]; then
            save_state "$PREV_STATUS" "$LAST_ALERT_TIME" "$FIRST_INCIDENT_TIME" "$LAST_REASONS"
        fi

    elif [ "$PREV_STATUS" = "CRITICAL" ]; then
        local sent=true
        if [ "$SEND_RESOLVE_ALERT" = true ]; then
            local dur=$(( CURRENT_TIME - FIRST_INCIDENT_TIME ))
            [ "$dur" -lt 60 ] && dur=60
            local msg
            msg="✅ <b>Всё снова в норме</b>
💻 <b>Хост:</b> <code>${host_html}</code>
⏳ <b>Проблема длилась:</b> ~$(format_duration "$dur")

📊 <b>Сейчас:</b>
⚡ CPU <code>${CPU_USAGE}%</code> · 🧠 RAM <code>${RAM_USAGE}%</code>"
            for i in "${!DISK_MOUNTS[@]}"; do
                msg+=" · 💾 $(html_escape "${DISK_MOUNTS[$i]}") <code>${DISK_USAGES[$i]}%</code>"
            done
            if [ "$DOCKER_AVAILABLE" = true ]; then
                msg+="
🐳 Docker: работает ${DOCKER_RUNNING} из ${DOCKER_TOTAL}"
            fi
            send_telegram "$msg" || sent=false
        fi
        # Если отчёт не ушёл — оставляем CRITICAL, чтобы отправить его на следующем запуске
        [ "$sent" = true ] && save_state "OK" 0 0 ""

    elif [ "$BOOT_ID" != "$CURRENT_BOOT_ID" ] || [ ! -f "$STATE_FILE" ]; then
        save_state "OK" 0 0 ""
    fi
}

# ==========================================================
# 7. Прочие команды
# ==========================================================
show_help() {
    cat <<EOF
🐧 uptimka v${UPTIMKA_VERSION} — мониторинг сервера с алертами в Telegram

Использование: uptimka [команда]

  (без аргументов)   показать дашборд
  -w, --watch        живой дашборд, обновление каждые 2 секунды (выход — Ctrl+C)
  --cron             фоновая проверка и алерты (для cron/systemd)
  --test             отправить тестовое сообщение в Telegram
  --uninstall        удалить uptimka с сервера
  -v, --version      показать версию
  -h, --help         эта справка

Конфиг: ${CONFIG_FILE}
Сайт:   https://github.com/nixlife-lab/uptimka
EOF
}

send_test() {
    collect_metrics
    local msg
    msg="🧪 <b>Тест uptimka v${UPTIMKA_VERSION}</b>
💻 <b>Хост:</b> <code>$(html_escape "$HOST_NAME")</code>
⚡ CPU <code>${CPU_USAGE}%</code> · 🧠 RAM <code>${RAM_USAGE}%</code>

Если вы это читаете — уведомления работают 👍"
    if send_telegram "$msg"; then
        echo "✅ Тестовое сообщение отправлено"
    else
        echo "❌ Не удалось отправить — проверьте BOT_TOKEN и CHAT_ID в ${CONFIG_FILE}"
        exit 1
    fi
}

uninstall() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ Запустите с правами root: sudo uptimka --uninstall"
        exit 1
    fi
    local answer=""
    read -rp "Удалить uptimka и его настройки? [y/N]: " answer < /dev/tty
    case "$answer" in y|Y|д|Д|yes|да) ;; *) echo "Отменено."; exit 0 ;; esac

    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/uptimka.timer ]; then
        systemctl disable --now uptimka.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/uptimka.timer /etc/systemd/system/uptimka.service
        systemctl daemon-reload
    fi
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v '/uptimka --cron' | crontab - 2>/dev/null
    fi
    rm -rf /etc/uptimka "$STATE_DIR"
    rm -f "$LOCK_FILE" /usr/local/bin/uptimka
    echo "🗑  uptimka удалён. Спасибо, что пользовались!"
}

watch_mode() {
    # Перерисовываем поверх, а не через clear — так экран не мерцает
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null; printf "\n"; exit 0' INT TERM
    clear
    local frame
    while true; do
        collect_metrics
        frame=$(render_dashboard)
        printf '\033[H%s\n' "${frame//$'\n'/$'\033[K\n'}"
        printf '%s\033[K\n\033[J' "${C_GRAY}  Обновление каждые 2 с · выход — Ctrl+C${C_RESET}"
        sleep 1
    done
}

# ==========================================================
# Точка входа
# ==========================================================
case "${1:-}" in
    -h|--help)      show_help ;;
    -v|--version)   echo "uptimka ${UPTIMKA_VERSION}" ;;
    -w|--watch)     watch_mode ;;
    --cron)         run_check ;;
    --test)         send_test ;;
    --uninstall)    uninstall ;;
    "")
        if [ -t 1 ]; then
            collect_metrics
            render_dashboard
        else
            run_check   # старое поведение: без терминала (из cron) — фоновая проверка
        fi
        ;;
    *)
        echo "Неизвестная команда: $1" >&2
        show_help >&2
        exit 2
        ;;
esac
