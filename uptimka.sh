#!/usr/bin/env bash
# uptimka — лёгкий мониторинг сервера на чистом Bash: TUI-дашборд + алерты в Telegram
# https://github.com/nixlife-lab/uptimka · MIT

set -o pipefail

UPTIMKA_VERSION="1.3.0"

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
REPORT="off"              # off / hourly / daily / weekly
REPORT_TIME="09:00"       # во сколько слать daily/weekly (время сервера)
REPORT_DAY=1              # день недели для weekly: 1 — пн … 7 — вс
DOCKER="auto"             # auto / off
PROXMOX="auto"            # auto / off
PROXMOX_GUESTS=""         # пусто — все VM/LXC, иначе ID через пробел
PROXMOX_IGNORE=""
GUEST_RAM_THRESHOLD=95
STORAGE_THRESHOLD=90
STORAGE_IGNORE=""
BACKUP_MAX_AGE_DAYS=0     # 0 — не следить за давностью бэкапов
SMART="auto"              # auto / off
SSD_WEAR_THRESHOLD=80
PVE_ETC="${UPTIMKA_PVE_ETC:-/etc/pve}"

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
check_pct GUEST_RAM_THRESHOLD 95
check_pct STORAGE_THRESHOLD 90
check_pct SSD_WEAR_THRESHOLD 80
if ! is_int "$BACKUP_MAX_AGE_DAYS"; then
    CONFIG_WARNINGS+=("BACKUP_MAX_AGE_DAYS=\"${BACKUP_MAX_AGE_DAYS}\" — не число, проверка давности бэкапов выключена")
    BACKUP_MAX_AGE_DAYS=0
fi
if ! is_int "$ALERT_COOLDOWN"; then
    CONFIG_WARNINGS+=("ALERT_COOLDOWN=\"${ALERT_COOLDOWN}\" — не число, взято 3600")
    ALERT_COOLDOWN=3600
fi
[ -z "$DISKS" ] && DISKS="/"
case "$REPORT" in
    off|hourly|daily|weekly) ;;
    *) CONFIG_WARNINGS+=("REPORT=\"${REPORT}\" — нужно off, hourly, daily или weekly; отчёты выключены")
       REPORT="off" ;;
esac
if [[ "$REPORT_TIME" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    REPORT_HM=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} ))
    printf -v REPORT_TIME '%02d:%02d' $(( 10#${BASH_REMATCH[1]} )) $(( 10#${BASH_REMATCH[2]} ))
else
    CONFIG_WARNINGS+=("REPORT_TIME=\"${REPORT_TIME}\" — нужно ЧЧ:ММ, взято 09:00")
    REPORT_TIME="09:00"; REPORT_HM=900
fi
if ! [[ "$REPORT_DAY" =~ ^[1-7]$ ]]; then
    CONFIG_WARNINGS+=("REPORT_DAY=\"${REPORT_DAY}\" — нужно 1–7, взят понедельник")
    REPORT_DAY=1
fi

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

    EXTRA_KEYS=(); EXTRA_TEXT=(); EXTRA_HTML=()
    if [ "$DOCKER_DOWN" = true ]; then
        add_problem "docker:daemon" "🐳 Docker установлен, но не отвечает" \
            "🐳 <b>Docker не отвечает</b> — служба остановлена или зависла (<code>systemctl status docker</code>)"
    fi
    collect_proxmox
    check_proxmox
    collect_smart
    check_smart
}

# ==========================================================
# 2. Docker: упавшие, OOM, unhealthy и перезапускающиеся по кругу
# ==========================================================
collect_docker() {
    DOCKER_AVAILABLE=false
    DOCKER_PROBLEMS=()
    DOCKER_RUNNING=0
    DOCKER_TOTAL=0

    DOCKER_DOWN=false
    [ "$DOCKER" = "off" ] && return 0
    command -v docker >/dev/null 2>&1 || return 0
    if ! docker info >/dev/null 2>&1; then
        # Без root docker info падает из-за прав — это не поломка
        [ "$(id -u)" -eq 0 ] && DOCKER_DOWN=true
        return 0
    fi
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
# 2b. Proxmox VE: гости (VM/LXC), хранилища, бэкапы
# ==========================================================
# Общие «дополнительные проблемы» (Proxmox, SSD): ключ для отслеживания, текст для дашборда и HTML для Telegram
EXTRA_KEYS=(); EXTRA_TEXT=(); EXTRA_HTML=()
add_problem() {   # add_problem ключ "текст" "html"
    EXTRA_KEYS+=("$1"); EXTRA_TEXT+=("$2"); EXTRA_HTML+=("$3")
}

human_bytes() {   # 296789571796 → «276 ГБ» (до 10 — с десятыми)
    awk -v b="$1" 'BEGIN {
        split("Б КБ МБ ГБ ТБ", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (b < 10 && i > 1) printf "%.1f %s", b, u[i]; else printf "%d %s", b + 0.5, u[i]
    }'
}

PVE_PARSER='
import json, sys
node = sys.argv[1]
data = json.load(open(sys.argv[2]))
nodes = [r.get("node") for r in data if r.get("type") == "node"]
if node not in nodes and len(nodes) == 1:
    node = nodes[0]
for r in data:
    if r.get("node") != node:
        continue
    t = r.get("type")
    if t in ("qemu", "lxc") and not r.get("template"):
        print("G|%s|%s|%s|%s|%d|%d|%d|%d|%d" % (r.get("vmid"), t, (r.get("name") or "").replace("|", "/"),
              r.get("status", "?"), round(float(r.get("cpu") or 0) * 100), int(r.get("mem") or 0),
              int(r.get("maxmem") or 0), int(r.get("disk") or 0), int(r.get("maxdisk") or 0)))
    elif t == "storage":
        print("S|%s|%s|%s|%d|%d" % (r.get("storage"), r.get("plugintype", "?"), r.get("status", "?"),
              int(r.get("disk") or 0), int(r.get("maxdisk") or 0)))
'

PVE_TASKS_PARSER='
import json, sys
seen = set()
for t in sorted(json.load(open(sys.argv[1])), key=lambda x: -int(x.get("starttime") or 0)):
    vid = str(t.get("id") or "")
    if not vid or vid in seen:
        continue
    seen.add(vid)
    print("B|%s|%d|%s" % (vid, int(t.get("endtime") or t.get("starttime") or 0), (t.get("status") or "?").replace("|", "/")))
'

PVE_AVAILABLE=false
PVE_NOTE=""
PVE_LAST=0
collect_proxmox() {
    [ "$PROXMOX" = "off" ] && return 0
    command -v pvesh >/dev/null 2>&1 && [ -d "$PVE_ETC" ] || return 0

    # В живом режиме дашборда опрашиваем Proxmox не чаще раза в 10 секунд — pvesh небыстрый
    [ "$PVE_AVAILABLE" = true ] && [ $(( CURRENT_TIME - PVE_LAST )) -lt 10 ] && return 0

    PVE_GUESTS=(); PVE_STORAGES=(); PVE_BACKUPS=()
    PVE_AVAILABLE=false
    if [ "$(id -u)" -ne 0 ]; then PVE_NOTE="нужен root — запустите через sudo"; return 0; fi
    if ! command -v python3 >/dev/null 2>&1; then PVE_NOTE="нужен python3 (apt install python3)"; return 0; fi

    local tmp node line
    tmp=$(mktemp)
    node=$(hostname -s 2>/dev/null || hostname)
    if ! pvesh get /cluster/resources --output-format json > "$tmp" 2>/dev/null; then
        PVE_NOTE="pvesh не ответил"; rm -f "$tmp"; return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            G\|*) PVE_GUESTS+=("${line#G|}") ;;
            S\|*) PVE_STORAGES+=("${line#S|}") ;;
        esac
    done < <(python3 -c "$PVE_PARSER" "$node" "$tmp" 2>/dev/null)

    if pvesh get "/nodes/${node}/tasks" --typefilter vzdump --limit 200 --output-format json > "$tmp" 2>/dev/null; then
        while IFS= read -r line; do
            PVE_BACKUPS+=("${line#B|}")
        done < <(python3 -c "$PVE_TASKS_PARSER" "$tmp" 2>/dev/null)
    fi
    rm -f "$tmp"

    PVE_AVAILABLE=true; PVE_NOTE=""; PVE_LAST=$CURRENT_TIME
}

pve_selected() {   # pve_selected vmid → проверять ли гостя
    in_list "$1" "$PROXMOX_IGNORE" && return 1
    [ -z "$PROXMOX_GUESTS" ] && return 0
    in_list "$1" "$PROXMOX_GUESTS"
}

pve_onboot() {     # pve_onboot vmid тип → включён ли автозапуск
    local f
    if [ "$2" = "lxc" ]; then f="${PVE_ETC}/lxc/$1.conf"; else f="${PVE_ETC}/qemu-server/$1.conf"; fi
    [ -r "$f" ] && sed '/^\[/q' "$f" | grep -q '^onboot: *1'
}

pve_backup_of() {  # pve_backup_of vmid → «время|статус» последнего бэкапа или пусто
    local b
    for b in "${PVE_BACKUPS[@]}"; do
        [ "${b%%|*}" = "$1" ] && { printf '%s' "${b#*|}"; return 0; }
    done
    return 1
}

pve_kind() { [ "$1" = "lxc" ] && printf 'LXC' || printf 'VM'; }

check_proxmox() {
    [ "$PVE_AVAILABLE" = true ] || return 0
    local g vmid type name status cpu mem maxmem disk maxdisk pct label label_html b bt bs age s sname sstatus sused smax
    for g in "${PVE_GUESTS[@]}"; do
        IFS='|' read -r vmid type name status cpu mem maxmem disk maxdisk <<< "$g"
        pve_selected "$vmid" || continue
        label="$(pve_kind "$type") ${vmid} ${name}"
        label_html="<b>$(pve_kind "$type") ${vmid}</b> <code>$(html_escape "$name")</code>"

        if [ "$status" != "running" ]; then
            if pve_onboot "$vmid" "$type"; then
                add_problem "pve:down:${vmid}" "🖥 ${label} — ${status}, хотя включён автозапуск" \
                    "🖥 ${label_html} — <b>${status}</b>, хотя включён автозапуск"
            fi
        else
            if [ "$maxmem" -gt 0 ]; then
                pct=$(( mem * 100 / maxmem ))
                [ "$pct" -ge "$GUEST_RAM_THRESHOLD" ] && add_problem "pve:ram:${vmid}" \
                    "🖥 ${label} — RAM ${pct}% ($(human_bytes "$mem") из $(human_bytes "$maxmem"))" \
                    "🖥 ${label_html} — RAM <code>${pct}%</code> ($(human_bytes "$mem") из $(human_bytes "$maxmem"))"
            fi
            if [ "$type" = "lxc" ] && [ "$maxdisk" -gt 0 ] && [ "$disk" -gt 0 ]; then
                pct=$(( disk * 100 / maxdisk ))
                [ "$pct" -ge "$DISK_THRESHOLD" ] && add_problem "pve:disk:${vmid}" \
                    "🖥 ${label} — диск ${pct}% ($(human_bytes "$disk") из $(human_bytes "$maxdisk"))" \
                    "🖥 ${label_html} — диск <code>${pct}%</code> ($(human_bytes "$disk") из $(human_bytes "$maxdisk"))"
            fi
        fi

        if b=$(pve_backup_of "$vmid"); then
            bt=${b%%|*}; bs=${b#*|}
            case "$bs" in
                OK|WARNINGS*) ;;
                *) add_problem "pve:backup-failed:${vmid}" "🗃 ${label} — бэкап с ошибкой: ${bs}" \
                       "🗃 ${label_html} — последний бэкап с ошибкой: <code>$(html_escape "$bs")</code>" ;;
            esac
            age=$(( (CURRENT_TIME - bt) / 86400 ))
            if [ "$BACKUP_MAX_AGE_DAYS" -gt 0 ] && [ "$age" -ge "$BACKUP_MAX_AGE_DAYS" ]; then
                add_problem "pve:backup-old:${vmid}" "🗃 ${label} — последний бэкап ${age} дн. назад" \
                    "🗃 ${label_html} — последний бэкап был <b>${age} дн. назад</b> (лимит ${BACKUP_MAX_AGE_DAYS})"
            fi
        fi
    done

    for s in "${PVE_STORAGES[@]}"; do
        IFS='|' read -r sname _ sstatus sused smax <<< "$s"
        in_list "$sname" "$STORAGE_IGNORE" && continue
        if [ "$sstatus" != "available" ]; then
            add_problem "pve:storage-down:${sname}" "🗄 Хранилище ${sname} недоступно" \
                "🗄 Хранилище <code>$(html_escape "$sname")</code> <b>недоступно</b>"
        elif [ "$smax" -gt 0 ]; then
            pct=$(( sused * 100 / smax ))
            [ "$pct" -ge "$STORAGE_THRESHOLD" ] && add_problem "pve:storage:${sname}" \
                "🗄 Хранилище ${sname} заполнено на ${pct}%" \
                "🗄 Хранилище <code>$(html_escape "$sname")</code> заполнено на <code>${pct}%</code> — свободно $(human_bytes $(( smax - sused )))"
        fi
    done
}

# ==========================================================
# 2c. Здоровье SSD/NVMe через smartctl
# ==========================================================
SMART_DISKS=()   # «устройство|модель|здоровье|износ%|записано|температура»
SMART_LAST=0
collect_smart() {
    [ "$SMART" = "off" ] && return 0
    command -v smartctl >/dev/null 2>&1 || return 0
    [ "$(id -u)" -eq 0 ] || return 0
    # SMART меняется медленно — в живом режиме читаем раз в минуту
    [ "${#SMART_DISKS[@]}" -gt 0 ] && [ $(( CURRENT_TIME - SMART_LAST )) -lt 60 ] && return 0
    SMART_DISKS=(); SMART_LAST=$CURRENT_TIME

    local dev opt out
    while read -r dev opt _; do
        [ -n "$dev" ] || continue
        out=$(LC_ALL=C smartctl -H -A -i -d "$opt" "$dev" 2>/dev/null) || [ -n "$out" ] || continue
        SMART_DISKS+=("$(awk -v dev="${dev#/dev/}" '
            /^(Model Number|Device Model):/        { sub(/^[^:]*: */, ""); model = $0 }
            /overall-health self-assessment/        { health = $NF }
            /^SMART Health Status:/                 { health = $NF }
            /^Critical Warning:/                    { if ($NF != "0x00") health = "WARNING" }
            /^Percentage Used:/                     { gsub(/%/, "", $NF); wear = $NF }
            /^Data Units Written:/                  { if (match($0, /\[[^]]*\]/)) written = substr($0, RSTART + 1, RLENGTH - 2) }
            /^Temperature:/                         { temp = $2 }
            /Temperature_Celsius/ && temp == ""     { temp = $10 }
            END { printf "%s|%s|%s|%s|%s|%s", dev, model, health, wear, written, temp }
        ' <<< "$out")")
    done < <(smartctl --scan 2>/dev/null | awk '{print $1, $3}')
}

check_smart() {
    local d dev model health wear written temp
    for d in "${SMART_DISKS[@]}"; do
        IFS='|' read -r dev model health wear written temp <<< "$d"
        case "$health" in
            PASSED|OK|"") ;;
            *) add_problem "smart:health:${dev}" "🩺 Диск ${dev} — SMART: ${health}" \
                   "🩺 <b>Диск ${dev}</b> ($(html_escape "$model")) — SMART: <b>${health}</b>. Пора сделать бэкап и подумать о замене" ;;
        esac
        if [ -n "$wear" ] && is_int "$wear" && [ "$wear" -ge "$SSD_WEAR_THRESHOLD" ]; then
            add_problem "smart:wear:${dev}" "🩺 Диск ${dev} — износ ${wear}%" \
                "🩺 <b>Диск ${dev}</b> ($(html_escape "$model")) — износ <code>${wear}%</code> ресурса"
        fi
    done
}

smart_line() {     # человекочитаемая строка о диске
    local dev model health wear written temp out
    IFS='|' read -r dev model health wear written temp <<< "$1"
    out="${dev}"
    [ -n "$model" ] && out+=" (${model})"
    [ -n "$wear" ] && out+=" · износ ${wear}%"
    [ -n "$written" ] && out+=" · записано ${written}"
    [ -n "$temp" ] && out+=" · ${temp}°C"
    case "$health" in PASSED|OK) out+=" · ✅ здоров" ;; "") ;; *) out+=" · ❗ ${health}" ;; esac
    printf '%s' "$out"
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

render_proxmox() {
    [ "$PROXMOX" = "off" ] && return 0
    if [ "$PVE_AVAILABLE" != true ]; then
        [ -n "$PVE_NOTE" ] && { section "🖥 Proxmox"; row "${C_YELLOW}${PVE_NOTE}${C_RESET}"; }
        return 0
    fi
    section "🖥 Proxmox"
    local g vmid type name status cpu mem maxmem disk maxdisk icon extra shown=0
    for g in "${PVE_GUESTS[@]}"; do
        IFS='|' read -r vmid type name status cpu mem maxmem disk maxdisk <<< "$g"
        pve_selected "$vmid" || continue
        shown=$(( shown + 1 ))
        if [ "$status" = "running" ]; then
            icon="🟢"
            extra="CPU $(printf '%3d' "$cpu")% · RAM $(human_bytes "$mem") / $(human_bytes "$maxmem")"
            if [ "$type" = "lxc" ] && [ "$maxdisk" -gt 0 ]; then
                extra+=" · диск $(( disk * 100 / maxdisk ))%"
            fi
        else
            if pve_onboot "$vmid" "$type"; then icon="🔴"; else icon="⚪"; fi
            extra="${C_GRAY}${status}${C_RESET}"
        fi
        row "$(printf '%s %-3s %-4s %-14s' "$icon" "$(pve_kind "$type")" "$vmid" "${name:0:14}") ${extra}"
    done
    [ "$shown" -eq 0 ] && row "${C_GRAY}гостей нет (или все исключены в конфиге)${C_RESET}"

    local s sname sstatus sused smax
    for s in "${PVE_STORAGES[@]}"; do
        IFS='|' read -r sname _ sstatus sused smax <<< "$s"
        in_list "$sname" "$STORAGE_IGNORE" && continue
        if [ "$sstatus" != "available" ] || [ "$smax" -le 0 ]; then
            row "🗄 $(printf '%-12s' "${sname:0:12}") ${C_RED}недоступно${C_RESET}"
        else
            row "🗄 $(printf '%-12s' "${sname:0:12}") $(draw_bar $(( sused * 100 / smax )) "$STORAGE_THRESHOLD")  ${C_GRAY}свободно $(human_bytes $(( smax - sused ))) из $(human_bytes "$smax")${C_RESET}"
        fi
    done

    local b bvmid bt bs age when
    for b in "${PVE_BACKUPS[@]}"; do
        IFS='|' read -r bvmid bt bs <<< "$b"
        pve_selected "$bvmid" || continue
        age=$(( (CURRENT_TIME - bt) / 86400 ))
        when=$(date -d "@${bt}" '+%d.%m.%Y' 2>/dev/null)
        case "$bs" in
            OK|WARNINGS*) icon="✅" ;;
            *) icon="❌" ;;
        esac
        row "🗃 Бэкап ${bvmid}: ${when} ${C_GRAY}(${age} дн. назад)${C_RESET} ${icon}"
    done
}

render_smart() {
    [ "${#SMART_DISKS[@]}" -gt 0 ] || return 0
    section "🩺 Диски (SMART)"
    local d
    for d in "${SMART_DISKS[@]}"; do row "$(smart_line "$d")"; done
}

render_dashboard() {
    local problems=0 i mp color
    [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ] && problems=$(( problems + 1 ))
    [ "$RAM_USAGE" -ge "$RAM_THRESHOLD" ] && problems=$(( problems + 1 ))
    for i in "${!DISK_USAGES[@]}"; do
        [ "${DISK_USAGES[$i]}" -ge "$DISK_THRESHOLD" ] && problems=$(( problems + 1 ))
    done
    problems=$(( problems + ${#DOCKER_PROBLEMS[@]} + ${#EXTRA_KEYS[@]} ))

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
    row "📬 Отчёты    $(report_schedule_text)"

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

    if [ "${#EXTRA_TEXT[@]}" -gt 0 ]; then
        section "🚨 Внимание"
        local t
        for t in "${EXTRA_TEXT[@]}"; do row "${C_RED}${t}${C_RESET}"; done
    fi

    render_proxmox
    render_smart

    if [ "$DOCKER" = "off" ] || ! command -v docker >/dev/null 2>&1; then
        :   # выключен в конфиге или не установлен — раздел не показываем
    elif [ "$DOCKER_AVAILABLE" != true ]; then
        section "🐳 Docker"
        if [ "$(id -u)" -ne 0 ]; then
            row "${C_GRAY}нет доступа — запустите через sudo${C_RESET}"
        else
            row "${C_YELLOW}установлен, но не отвечает (отключить проверку: DOCKER=\"off\")${C_RESET}"
        fi
    else
        section "🐳 Docker"
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
PREV_STATUS="OK"          # OK / CRITICAL
LAST_ALERT_TIME=0
FIRST_INCIDENT_TIME=0
LAST_REASONS=""
BOOT_ID=""
LAST_REPORT_SLOT=""       # какой период уже покрыт регулярным отчётом
PERIOD_START=0            # статистика с момента прошлого отчёта
PERIOD_INCIDENTS=0
PERIOD_CHECKS=0
PEAK_CPU=0
PEAK_RAM=0

STATE_KEYS="PREV_STATUS LAST_ALERT_TIME FIRST_INCIDENT_TIME LAST_REASONS BOOT_ID LAST_REPORT_SLOT PERIOD_START PERIOD_INCIDENTS PERIOD_CHECKS PEAK_CPU PEAK_RAM"

load_state() {
    [ -r "$STATE_FILE" ] || return 0
    # Читаем как «ключ=значение», а не через source — файл не выполняется как код
    local key value
    while IFS='=' read -r key value; do
        in_list "$key" "$STATE_KEYS" || continue
        case "$key" in
            PREV_STATUS|LAST_REASONS|BOOT_ID|LAST_REPORT_SLOT) printf -v "$key" '%s' "$value" ;;
            *) is_int "$value" && printf -v "$key" '%s' "$value" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    mkdir -p "$STATE_DIR"
    local tmp="${STATE_FILE}.tmp" key
    for key in $STATE_KEYS; do
        printf '%s=%s\n' "$key" "${!key}"
    done > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# ==========================================================
# 6. Регулярный отчёт (REPORT=hourly / daily / weekly)
# ==========================================================
# Возвращает «номер» текущего периода, если время отчёта в нём уже наступило, иначе пусто.
# Отчёт уходит один раз за период — при первой проверке после REPORT_TIME, поэтому
# работает при любом интервале проверок и не дублируется.
report_slot() {
    local now_hm today_dow
    now_hm=$(date +%H%M)
    case "$REPORT" in
        hourly)
            date +%Y%m%d%H
            ;;
        daily)
            [ "$now_hm" -ge "$REPORT_HM" ] && date +%Y%m%d
            ;;
        weekly)
            today_dow=$(date +%u)
            if [ "$today_dow" -gt "$REPORT_DAY" ] || { [ "$today_dow" -eq "$REPORT_DAY" ] && [ "$now_hm" -ge "$REPORT_HM" ]; }; then
                date +%G-W%V
            fi
            ;;
    esac
}

build_report() {
    local host_html period_name="" i mp status_line peaks
    host_html=$(html_escape "$HOST_NAME")
    case "$REPORT" in
        hourly) period_name="За час" ;;
        daily)  period_name="За сутки" ;;
        weekly) period_name="За неделю" ;;
        *)      period_name="С прошлого отчёта" ;;
    esac

    if [ "$PREV_STATUS" = "CRITICAL" ]; then
        status_line="🚨 <b>Сейчас есть проблема</b> — подробности в последнем алерте"
    else
        status_line="✅ <b>Сейчас всё в норме</b>"
    fi

    local report
    report="📊 <b>Отчёт о сервере</b> · $(date '+%d.%m.%Y %H:%M')
💻 <b>Хост:</b> <code>${host_html}</code>
⏰ <b>Аптайм:</b> ${UPTIME_STR}
${status_line}

<b>Сейчас:</b>
⚡ CPU <code>${CPU_USAGE}%</code> · нагрузка ${LOAD1} / ${LOAD5} / ${LOAD15} (ядер: ${CPU_CORES})
🧠 RAM <code>${RAM_USAGE}%</code> — ${RAM_USED} из ${RAM_TOTAL} МБ"
    [ "$SWAP_TOTAL" -gt 0 ] && report+="
🔁 Swap ${SWAP_USED} из ${SWAP_TOTAL} МБ"
    for i in "${!DISK_MOUNTS[@]}"; do
        mp=${DISK_MOUNTS[$i]}
        report+="
💾 Диск $(html_escape "$mp") <code>${DISK_USAGES[$i]}%</code> — свободно ${DISK_FREES[$i]} из ${DISK_SIZES[$i]}"
    done
    [ -n "$CPU_TEMP" ] && report+="
🔥 Температура CPU ${CPU_TEMP}°C"
    if [ "$DOCKER_AVAILABLE" = true ]; then
        if [ "${#DOCKER_PROBLEMS[@]}" -eq 0 ]; then
            report+="
🐳 Docker: работает ${DOCKER_RUNNING} из ${DOCKER_TOTAL}, проблем нет"
        else
            report+="
🐳 Docker: работает ${DOCKER_RUNNING} из ${DOCKER_TOTAL}, проблемных: ${#DOCKER_PROBLEMS[@]}"
        fi
    fi
    report+="$(report_proxmox_html)"
    if [ "${#SMART_DISKS[@]}" -gt 0 ]; then
        local d
        for d in "${SMART_DISKS[@]}"; do
            report+="
🩺 $(html_escape "$(smart_line "$d")")"
        done
    fi
    if [ "${#EXTRA_HTML[@]}" -gt 0 ]; then
        report+="

<b>Требует внимания:</b>"
        local x
        for x in "${EXTRA_HTML[@]}"; do report+="
${x}"; done
    fi

    if [ "$PERIOD_CHECKS" -gt 0 ]; then
        peaks="⚡ CPU до <code>${PEAK_CPU}%</code> · 🧠 RAM до <code>${PEAK_RAM}%</code>"
        report+="

<b>${period_name}:</b>
📈 Пики по замерам: ${peaks}"
        if [ "$PERIOD_INCIDENTS" -eq 0 ]; then
            report+="
🟢 Без происшествий"
        else
            report+="
🟠 Проблем: ${PERIOD_INCIDENTS}"
        fi
    fi

    report+="

🏆 <b>Топ процессов по памяти:</b>
$(top_processes_html)"
    printf '%s' "$report"
}

report_proxmox_html() {
    [ "$PVE_AVAILABLE" = true ] || return 0
    local out="" g vmid type name status cpu mem maxmem disk maxdisk icon
    out+="

🖥 <b>Proxmox:</b>"
    for g in "${PVE_GUESTS[@]}"; do
        IFS='|' read -r vmid type name status cpu mem maxmem disk maxdisk <<< "$g"
        pve_selected "$vmid" || continue
        if [ "$status" = "running" ]; then
            out+="
🟢 $(pve_kind "$type") ${vmid} <b>$(html_escape "$name")</b> — CPU ${cpu}% · RAM $(human_bytes "$mem") из $(human_bytes "$maxmem")"
            [ "$type" = "lxc" ] && [ "$maxdisk" -gt 0 ] && out+=" · диск $(( disk * 100 / maxdisk ))%"
        else
            if pve_onboot "$vmid" "$type"; then icon="🔴"; else icon="⚪"; fi
            out+="
${icon} $(pve_kind "$type") ${vmid} <b>$(html_escape "$name")</b> — ${status}"
        fi
    done
    local s sname sstatus sused smax
    for s in "${PVE_STORAGES[@]}"; do
        IFS='|' read -r sname _ sstatus sused smax <<< "$s"
        in_list "$sname" "$STORAGE_IGNORE" && continue
        if [ "$sstatus" != "available" ] || [ "$smax" -le 0 ]; then
            out+="
🗄 $(html_escape "$sname") — <b>недоступно</b>"
        else
            out+="
🗄 $(html_escape "$sname") <code>$(( sused * 100 / smax ))%</code> — свободно $(human_bytes $(( smax - sused ))) из $(human_bytes "$smax")"
        fi
    done
    local b bvmid bt bs ok
    for b in "${PVE_BACKUPS[@]}"; do
        IFS='|' read -r bvmid bt bs <<< "$b"
        pve_selected "$bvmid" || continue
        case "$bs" in OK|WARNINGS*) ok="✅" ;; *) ok="❌" ;; esac
        out+="
🗃 Бэкап ${bvmid}: $(date -d "@${bt}" '+%d.%m.%Y' 2>/dev/null) ($(( (CURRENT_TIME - bt) / 86400 )) дн. назад) ${ok}"
    done
    printf '%s' "$out"
}

reset_period() {
    PERIOD_START=$CURRENT_TIME
    PERIOD_INCIDENTS=0
    PERIOD_CHECKS=0
    PEAK_CPU=0
    PEAK_RAM=0
}

# ==========================================================
# 7. Фоновая проверка (cron / systemd timer)
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
    local first_run=false
    [ -f "$STATE_FILE" ] || first_run=true
    load_state
    [ "$PERIOD_START" -eq 0 ] && reset_period

    local host_html current_boot
    host_html=$(html_escape "$HOST_NAME")
    current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

    # --- Перезагрузка
    if [ "$NOTIFY_REBOOT" = true ] && [ -n "$BOOT_ID" ] && [ "$BOOT_ID" != "$current_boot" ]; then
        local rmsg="🔄 <b>Сервер перезагрузился</b>
💻 <b>Хост:</b> <code>${host_html}</code>
⏰ <b>Работает:</b> ${UPTIME_STR}"
        send_telegram "$rmsg" || true
    fi
    BOOT_ID=$current_boot

    # --- Статистика для регулярного отчёта
    PERIOD_CHECKS=$(( PERIOD_CHECKS + 1 ))
    [ "$CPU_USAGE" -gt "$PEAK_CPU" ] && PEAK_CPU=$CPU_USAGE
    [ "$RAM_USAGE" -gt "$PEAK_RAM" ] && PEAK_RAM=$RAM_USAGE

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
    for i in "${!EXTRA_KEYS[@]}"; do
        keys+=("${EXTRA_KEYS[$i]}"); lines+=("${EXTRA_HTML[$i]}")
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
                [ "$PREV_STATUS" != "CRITICAL" ] && PERIOD_INCIDENTS=$(( PERIOD_INCIDENTS + 1 ))
                PREV_STATUS="CRITICAL"
                LAST_ALERT_TIME=$CURRENT_TIME
                FIRST_INCIDENT_TIME=$first
                LAST_REASONS=$reasons_key
            fi
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
        # Если сообщение не ушло — оставляем CRITICAL, чтобы отправить его на следующем запуске
        if [ "$sent" = true ]; then
            PREV_STATUS="OK"; LAST_ALERT_TIME=0; FIRST_INCIDENT_TIME=0; LAST_REASONS=""
        fi
    fi

    # --- Регулярный отчёт
    if [ "$REPORT" != "off" ]; then
        local slot
        slot=$(report_slot)
        if [ -n "$slot" ] && [ "$slot" != "$LAST_REPORT_SLOT" ]; then
            if [ "$first_run" = true ] || [ -z "$LAST_REPORT_SLOT" ]; then
                # Только что установили (или включили отчёты) — первый отчёт будет в следующем периоде
                LAST_REPORT_SLOT=$slot
            elif send_telegram "$(build_report)"; then
                LAST_REPORT_SLOT=$slot
                reset_period
            fi
        fi
    fi

    save_state
}

# ==========================================================
# 8. Прочие команды
# ==========================================================
show_help() {
    cat <<EOF
🐧 uptimka v${UPTIMKA_VERSION} — мониторинг сервера с алертами в Telegram

Использование: uptimka [команда]

  (без аргументов)   показать дашборд
  -w, --watch        живой дашборд, обновление каждые 2 секунды (выход — Ctrl+C)
  --cron             фоновая проверка и алерты (для cron/systemd)
  --test             отправить тестовое сообщение в Telegram
  --report           отправить отчёт о состоянии сервера прямо сейчас
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

send_report_now() {
    collect_metrics
    [ -r "$STATE_FILE" ] && load_state
    if send_telegram "$(build_report)"; then
        echo "✅ Отчёт отправлен"
    else
        echo "❌ Не удалось отправить — проверьте BOT_TOKEN и CHAT_ID в ${CONFIG_FILE}"
        exit 1
    fi
}

report_schedule_text() {
    local days=(пн вт ср чт пт сб вс)
    case "$REPORT" in
        hourly) printf 'каждый час' ;;
        daily)  printf 'каждый день в %s' "$REPORT_TIME" ;;
        weekly) printf 'по %s в %s' "${days[$((REPORT_DAY - 1))]}" "$REPORT_TIME" ;;
        *)      printf 'выключены' ;;
    esac
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
    --report)       send_report_now ;;
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
