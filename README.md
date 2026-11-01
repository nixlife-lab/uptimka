# 🐧 nix-monitor

<p align="center">
  <img src="https://img.shields.io/badge/bash-5.0+-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Bash" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" alt="License" />
  <img src="https://img.shields.io/badge/docker-compatible-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker" />
  <img src="https://img.shields.io/badge/telegram-alerts-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram" />
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen?style=for-the-badge" alt="Zero Dependencies" />
</p>

<p align="center">
  <b>Легковесный zero-dependency агент мониторинга серверов и хоумлабов на чистом Bash.</b><br>
  Консольный TUI-дашборд, трекинг сбоев Docker-контейнеров, умные алерты в Telegram с защитой от спама (cooldown) и автооповещением о восстановлении (resolve).
</p>

---

## ⚡️ Особенности

- 🪶 **0 МБ постоянной памяти:** запускается по cron, отрабатывает за доли секунды и полностью выгружается.
- 🚫 **Zero Dependencies:** использует только стандартные утилиты Linux (`/proc/stat`, `/sys/class/thermal`, `awk`, `curl`, `df`, `free`).
- 🛡 **Умный антиспам (Alert Cooldown):** если нагрузка держится долго, повторный алерт придет только через 60 минут, не забивая чат.
- 🟢 **Resolve Notifications:** при стабилизации нагрузки бот присылает сообщение о восстановлении и длительности сбоя.
- 🐳 **Docker Healthcheck:** находит упавшие контейнеры (`exited` с ошибкой), игнорируя штатно завершенные cron-задачи.
- 📊 **TUI-дашборд:** цветная консольная панель с псевдографическими шкалами и живым режимом мониторинга.

---

## 🚀 Быстрая установка

```bash
curl -sSL [https://raw.githubusercontent.com/Flyerrs/nix-monitor/main/install.sh](https://raw.githubusercontent.com/Flyerrs/nix-monitor/main/install.sh) | sudo bash
