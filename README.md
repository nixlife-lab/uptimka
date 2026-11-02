# 🐧 uptimka

<div align="center">

![Bash](https://img.shields.io/badge/bash-5.0+-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)
![Docker](https://img.shields.io/badge/docker-compatible-2496ED?style=flat-square&logo=docker&logoColor=white)
![Telegram](https://img.shields.io/badge/telegram-alerts-26A5E4?style=flat-square&logo=telegram&logoColor=white)
![Zero Dependencies](https://img.shields.io/badge/dependencies-zero-brightgreen?style=flat-square)

**Легковесный zero-dependency агент мониторинга серверов и хоумлабов на чистом Bash.**  
Консольный TUI-дашборд, трекинг сбоев Docker-контейнеров, умные алерты в Telegram с защитой от спама (cooldown) и автооповещением о восстановлении (resolve).

</div>

---

## ⚡️ Почему uptimka?

Большинство систем мониторинга избыточны для одиночных VPS или домашних серверов: они потребляют от сотен мегабайт RAM и требуют сложной настройки.

**uptimka** решает задачу иначе:
- 🪶 **0 МБ постоянной памяти:** запускается по cron, отрабатывает за доли секунды и полностью выгружается.
- 🚫 **Zero Dependencies:** использует только штатные интерфейсы ядра (`/proc/stat`, `/sys/class/thermal`, `awk`, `curl`, `df`, `free`).
- 🛡 **Умный антиспам (Alert Cooldown):** если нагрузка держится долго, повторный алерт придет только через заданный интервал (по умолчанию 60 минут).
- 🟢 **Resolve Notifications:** при стабилизации нагрузки бот автоматически присылает отчет о восстановлении и длительности сбоя.
- 🐳 **Docker Healthcheck:** находит аварийно завершенные контейнеры (`exited` с ошибкой), игнорируя штатно завершенные задачи с кодом 0.
- 📊 **TUI-дашборд:** цветная консольная панель с псевдографическими шкалами и живым режимом мониторинга.

---

## 🖥 Консольный интерфейс (TUI)

Запустите утилиту без аргументов в терминале для быстрой оценки состояния сервера:

```text
======================= uptimka =======================
  Хост:          vps-node-01
  Аптайм:        28 days, 14 hours
  Темп. CPU:     43°C (Load: 0.18, 0.22, 0.15)
  Docker:        8 активен / 9 всего (1 краш!)
-----------------------------------------------------------
  РЕСУРСЫ СИСТЕМЫ
  CPU:  [■■··················]  12%   (Порог: 85%)
  RAM:  [■■■■■■■·············]  38%   760M/2000M
  ДИСК: [■■■■■■■■■■■·········]  56%   Своб: 13G (30G)
-----------------------------------------------------------
  УПАВШИЕ DOCKER-КОНТЕЙНЕРЫ
  ✖ postgres-db (Exit 1)
-----------------------------------------------------------
  ТОП-3 ПРОЦЕССОВ (RAM / CPU)
  • dockerd             11.4% RAM    0.4% CPU
  • caddy                2.1% RAM    0.1% CPU
  • python3              1.9% RAM    1.2% CPU
===========================================================
```

---

## 📲 Уведомления в Telegram

### 1. Сообщение об инциденте
Отправляется мгновенно при превышении порогов или падении контейнера:

> 🚨 **[ALERT] Инцидент на сервере!**  
> 🖥 **Хост:** `vps-node-01`  
> ⏱ **Uptime:** `28 days, 14 hours`  
>  
> 🔴 **RAM:** `94%` (Порог: 90%)  
> 💥 **Docker: обнаружены упавшие контейнеры!**  
> &nbsp;&nbsp;✖ `postgres-db (Exit 1)`  
>  
> **Топ процессов по RAM:**  
> • dockerd (PID 812): 11.4% RAM, 0.4% CPU  
> • node (PID 3401): 8.2% RAM, 2.1% CPU  

### 2. Сообщение о восстановлении (Resolve)
Приходит автоматически, когда показатели возвращаются в норму:

> ✅ **[RESOLVED] Работа сервера стабилизирована!**  
> 🖥 **Хост:** `vps-node-01`  
> ⏳ **Длительность сбоя:** ~14 мин.  
>  
> 📊 **Текущие показатели:**  
> • CPU: `4%`  
> • RAM: `38%`  
> • Диск: `56%`  
> • Docker: `Все контейнеры в строю (9/9)`  

---

## 🚀 Быстрая установка

Запустите установщик одной командой:

```bash
curl -sSL https://raw.githubusercontent.com/nixlife-lab/uptimka/main/install.sh | sudo bash
```

Установщик запросит `Bot Token` и `Chat ID`, проверит отправку тестового сообщения и добавит задачу проверки в `cron`.

---

## ⚙️ Конфигурация (`/etc/uptimka/uptimka.conf`)

```bash
# Telegram Bot Credentials
BOT_TOKEN="123456789:ABCdefGHIjklMNOprst"
CHAT_ID="987654321"

# Пороги срабатывания алертов (в процентах)
CPU_THRESHOLD=85
RAM_THRESHOLD=90
DISK_THRESHOLD=90

# Защита от спама (секунды): интервал повторного алерта при длительном сбое
ALERT_COOLDOWN=3600

# Уведомление о нормализации метрик (true/false)
SEND_RESOLVE_ALERT=true
```

---

## 📖 Использование в терминале

| Команда | Описание |
| :--- | :--- |
| `uptimka` | Вывести аккуратный TUI-дашборд с текущими показателями |
| `uptimka -w` | Запустить живой режим с автообновлением каждые 2 секунды |
| `uptimka --cron` | Фоновый запуск для планировщика cron |

---

## 🗑 Удаление

```bash
sudo rm -f /usr/local/bin/uptimka
sudo rm -rf /etc/uptimka
sudo rm -f /var/run/uptimka.state
crontab -l | grep -v 'uptimka' | crontab -
```

---

## 📄 Лицензия

Проект распространяется под лицензией [MIT](LICENSE). Разработано для блога [nixlife.ru](https://nixlife.ru).
