# 🐧 nix-monitor

<p align="center">
  <img src="[https://img.shields.io/badge/bash-5.0+-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white](https://img.shields.io/badge/bash-5.0+-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)" alt="Bash" />
  <img src="[https://img.shields.io/badge/license-MIT-blue?style=for-the-badge](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)" alt="License" />
  <img src="[https://img.shields.io/badge/docker-compatible-2496ED?style=for-the-badge&logo=docker&logoColor=white](https://img.shields.io/badge/docker-compatible-2496ED?style=for-the-badge&logo=docker&logoColor=white)" alt="Docker" />
  <img src="[https://img.shields.io/badge/telegram-alerts-26A5E4?style=for-the-badge&logo=telegram&logoColor=white](https://img.shields.io/badge/telegram-alerts-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)" alt="Telegram" />
  <img src="[https://img.shields.io/badge/dependencies-zero-brightgreen?style=for-the-badge](https://img.shields.io/badge/dependencies-zero-brightgreen?style=for-the-badge)" alt="Zero Dependencies" />
</p>

<p align="center">
  <b>Легковесный zero-dependency агент мониторинга серверов и хоумлабов на чистом Bash.</b><br>
  Консольный TUI-дашборд, трекинг сбоев Docker-контейнеров, умные алерты в Telegram с защитой от спама (cooldown) и автооповещением о восстановлении (resolve).
</p>

---

## ⚡️ Почему nix-monitor?

Большинство систем мониторинга избыточны для одиночных VPS или домашних серверов: они потребляют от сотен мегабайт RAM и требуют сложной настройки.

**nix-monitor** решает задачу иначе:
- 🪶 **0 МБ постоянной памяти:** запускается по cron, отрабатывает за доли секунды и полностью выгружается.
- 🚫 **Zero Dependencies:** использует только штатные интерфейсы ядра (`/proc/stat`, `/sys/class/thermal`, `awk`, `curl`, `df`, `free`).
- 🛡 **Умный антиспам (Alert Cooldown):** если нагрузка держится долго, повторный алерт придет только через заданный интервал (по умолчанию 60 минут).
- 🟢 **Resolve Notifications:** при стабилизации нагрузки бот автоматически присылает отчет о восстановлении и длительности сбоя.
- 🐳 **Docker Healthcheck:** находит аварийно завершенные контейнеры (`exited` с ошибкой), игнорируя штатно завершенные задачи с кодом 0.
- 📊 **TUI-дашборд:** цветная консольная панель с псевдографическими шкалами и живым режимом мониторинга.

---

## 🖥 Консольный интерфейс (TUI)

Запустите утилиту без аргументов в терминале для оценки состояния сервера:

```text
┌────────────────────────────────────────────────────────┐
│  🐧 nix-monitor :: Панель управления сервером         │
├────────────────────────────────────────────────────────┤
│  🖥  Хост:          vps-node-01                        │
│  ⏱  Аптайм:        28 days, 14 hours                  │
│  🌡  Темп. CPU:     43°C  (Load: 0.18, 0.22, 0.15)      │
│  🐳 Docker:         8 активен / 9 всего (1 краш!)      │
├────────────────────────────────────────────────────────┤
│  РЕСУРСЫ СИСТЕМЫ                                       │
│  CPU:  [■■··················]  12%   (Порог: 85%)      │
│  RAM:  [■■■■■■■·············]  38%   760M/2000M        │
│  ДИСК: [■■■■■■■■■■■·········]  56%   Своб: 13G (30G)   │
├────────────────────────────────────────────────────────┤
│  ⚠️ УПАВШИЕ DOCKER-КОНТЕЙНЕРЫ                          │
│  ✖ postgres-db (Exit exited (1))                       │
├────────────────────────────────────────────────────────┤
│  ТОП-3 ПРОЦЕССОВ (RAM / CPU)                           │
│  • dockerd             11.4% RAM    0.4% CPU           │
│  • caddy                2.1% RAM    0.1% CPU           │
│  • python3              1.9% RAM    1.2% CPU           │
└────────────────────────────────────────────────────────┘
