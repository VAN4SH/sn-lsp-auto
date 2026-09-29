# sn-lsp-auto — установка и настройка Secret Net LSP

Набор bash-скриптов для установки **Secret Net LSP** (+ опционально **ПМЭ**) и последующей настройки политик через текстовое меню.

Поддерживаемые ОС:

| ОС | Пакеты (пример) |
|----|-----------------|
| Astra Linux CE **2.12** (и SE 1.7 / 1.8) | `sn-lsp_*astra*.deb`, `snlsp-firewall_*astra*.deb` |
| РЕД ОС **8** | `sn-lsp*redos*.rpm`, `snlsp-firewall*red*.rpm` |
| ALT Linux СП (**c10f1** и др.) | `sn-lsp*alt*.rpm`, `snlsp-firewall*alt*.rpm` |

Скрипты рассчитаны на разные сборки SN (2509, 334, …): матрица ядер и зависимости берутся **из пакета**, а не из захардкоженного списка.

---

## Состав

| Файл | Назначение |
|------|------------|
| `install_sn_lsp.sh` | Автоустановка SN (ядро → пакет → reboot → ПМЭ → лицензия) |
| `configure_sn_lsp.sh` | Интерактивное меню настройки политик SN |
| `backup_sn_policies.sh` | Бэкап / сравнение / откат политик (`snpolctl`) |
| `ansible/` | Плейбуки диагностики и массовой установки с jump-хоста |
| `packages*` / `packages-astra` / `packages-alt` | Каталоги с deb/rpm и `.lic` (кладите сами) |

---

## `install_sn_lsp.sh`

### Что делает

1. Определяет ОС (Astra / РЕД ОС / ALT).
2. Находит в `--pkg-dir` пакеты SN и ПМЭ.
3. Читает **матрицу ядер** из содержимого пакета SN (`/lib/modules/<uname -r>/…`).
4. Если текущее ядро не из матрицы — подключает репозитории ОС (при необходимости зеркала), ищет/ставит подходящее ядро (локальный файл в `--pkg-dir`, DVD, dnf/apt, зеркала).
5. Ставит зависимости SN (boost, libmhash, sudo и т.д.).
6. Устанавливает SN → перезагрузка → ПМЭ → лицензия.
7. **Политики не трогает** — это зона `configure_sn_lsp.sh` / ручной настройки под заказчика.

Состояние этапов: `/var/lib/sn-lsp-autoinstall/state`  
Лог: `/var/lib/sn-lsp-autoinstall/install.log`

После reboot запускайте **ту же команду** — скрипт продолжит с сохранённого этапа.

### Этапы (PHASE)

| PHASE | Действие |
|-------|----------|
| **0** | Проверка/смена ядра → reboot → 1 |
| **1** | Установка пакета SN → reboot → 3 |
| **3** | ПМЭ + лицензия → 5 |
| **5** | Готово |

### Запуск

```bash
# от root
sudo bash install_sn_lsp.sh \
  --pkg-dir ./packages-astra \
  --license ./packages-astra/26962ED_key.lic
```

Примеры каталогов:

```bash
# Astra
--pkg-dir ./packages-astra

# РЕД ОС
--pkg-dir ./packages

# ALT
--pkg-dir ./packages-alt
```

Офлайн: положите в `--pkg-dir` также `kernel-*.rpm` / `linux-image-*.deb` из матрицы — скрипт подхватит их без сети.

### Опции

| Опция | Описание |
|-------|----------|
| `--pkg-dir DIR` | Каталог с пакетами SN/ПМЭ (**обязательно**) |
| `--license FILE` | Файл `.lic` (опционально) |
| `--skip-kernel` | Не менять ядро (если несовместимо — ошибка) |
| `--skip-firewall` | Не ставить ПМЭ |
| `--skip-repos` | Не дописывать репозитории ОС |
| `--no-reboot` | Не перезагружать (код выхода 2, если reboot нужен) |
| `--force-phase N` | Начать с этапа `0`…`5` |
| `--dry-run` | Только план |
| `-h` / `--help` | Справка |

### Репозитории

Если в `sources.list` / yum пусто, только примеры или cdrom — скрипт сам подключает рабочие зеркала:

- **Astra** — `dl.astralinux.ru` / `download.astralinux.ru` (CE 2.12 / SE 1.7 / 1.8 по пакету и ОС)
- **РЕД ОС** — Yandex + repo.red-soft.ru
- **ALT** — Yandex / ftp.altlinux.org / update.altsp.su, **без** vendor-тегов `[alt]` (на СП они часто ломают apt)

Повтор установки «с нуля»:

```bash
sudo rm -rf /var/lib/sn-lsp-autoinstall
sudo bash install_sn_lsp.sh --pkg-dir ... --license ...
```

---

## `configure_sn_lsp.sh`

### Что делает

Меню для первой настройки: пункты на русском, варианты «включить / 5 попыток / 30 минут». Имена политик вводить не нужно — скрипт сам вызывает `snpolctl`.

Нужен уже установленный SN (`snpolctl` в PATH).

```bash
sudo bash configure_sn_lsp.sh
```

| № | Раздел |
|---|--------|
| **1** | Обычный набор: сложный пароль, 5 ошибок / 30 мин, контроль целостности, память, журналы. Блокировку всей станции не включает. |
| **2–6** | Пароли, целостность, память, журналы, USB/сеть/запуск программ. У каждого пункта видно текущее состояние и список готовых значений. |
| **7** | Лицензия `.lic` и разблокировка |
| **8** | Сводка человеческим языком |
| **9** | Службы Secret Net |

---

## `backup_sn_policies.sh`

Бэкап политик после настройки (или перед экспериментами), сравнение и простой откат.

```bash
sudo bash backup_sn_policies.sh backup
sudo bash backup_sn_policies.sh list
sudo bash backup_sn_policies.sh compare 2026-09-21_131500          # бэкап ↔ сейчас
sudo bash backup_sn_policies.sh compare DIR_A DIR_B
sudo bash backup_sn_policies.sh restore 2026-09-21_131500 --dry-run
sudo bash backup_sn_policies.sh restore 2026-09-21_131500 --yes
sudo bash backup_sn_policies.sh show 2026-09-21_131500
```

Каталог: `/var/lib/sn-lsp-autoinstall/policy-backups/<timestamp>/`  
Файлы: `snpolctl-l.txt`, `plugins/*.txt`, `apply.txt` (строки `PLUGIN|политика,параметр,значение` для отката).

Откат применяет только распознанные параметры из `apply.txt`, не «заливает» сырой `-l` целиком.

---

## Типовой порядок работ

1. Положить в каталог пакеты под нужную ОС + `.lic`.
2. Установить:

   ```bash
   sudo bash install_sn_lsp.sh --pkg-dir ./packages-… --license ./packages-…/ключ.lic
   ```

3. После финального reboot (PHASE=5) настроить политики:

   ```bash
   sudo bash configure_sn_lsp.sh
   ```

4. При необходимости — быстрый шаблон (п. 10), затем точечная донастройка под заказчика.
5. Снять снимок политик: `sudo bash backup_sn_policies.sh backup`.

---

## Ansible (массовая установка с jump-хоста)

Bash-скрипты остаются установщиком. Ansible только собирает факты, копирует комплект и запускает `install_sn_lsp.sh` с учётом reboot/PHASE.

На jump нужны: Ansible 2.12+, SSH к АРМ/серверам, sudo, Python3. Пакеты и `.lic` в git не кладутся.

### Подготовка

```bash
cd ansible
cp inventory/hosts.example.ini inventory/hosts.ini
# заполнить [arm] и [servers]

mkdir -p files/packages-astra files/packages files/packages-alt
# положить sn-lsp / snlsp-firewall и .lic в нужный каталог

# в group_vars/all.yml указать, например:
# sn_license_src: packages-astra/26962ED_key.lic
```

Доставка пакетов:

- `sn_pkg_mode: copy` (по умолчанию) — копирование с jump на каждый хост;
- `sn_pkg_mode: mirror` + `sn_pkg_url` или `sn_pkg_share` — пакеты с HTTP/общего каталога.

Группы: у `arm` `sn_serial: 5`, у `servers` `sn_serial: 1`.

### Порядок

```bash
# 1) Диагностика → ansible/reports/<timestamp>/summary.csv, ready.txt, blocked.txt
ansible-playbook playbooks/01-diagnose.yml

# 2) Вручную сверить CSV (ОС, диск, kernel_in_matrix, notes)

# 3) Пилот или волна
ansible-playbook playbooks/02-install.yml --limit arm-01
ansible-playbook playbooks/02-install.yml --limit @reports/<timestamp>/ready.txt

# 4) Контроль
ansible-playbook playbooks/03-status.yml --limit @reports/<timestamp>/ready.txt
```

Политики массово не применяются — после PHASE=5 на пилоте: `configure_sn_lsp.sh` / `backup_sn_policies.sh`.

---

## Важно

- **Ядро:** `uname -r` должен совпасть с записью в матрице **конкретного** пакета SN. Новая сборка SN → другая матрица; скрипт установки это учитывает автоматически.
- **Политики** зависят от лицензии и установленных механизмов (ПМЭ, ЗПС и т.д.).
- Скрипты пишите/копируйте с **LF** (не CRLF), иначе bash на Linux может падать.
- Нужны права **root**.

---

## Быстрая справка команд SN

| Утилита | Назначение |
|---------|------------|
| `snlicensectl -s` / `-c file.lic` | Статус / установка лицензии |
| `snunblock` | Разблокировка станции |
| `snpolctl -l` | Список политик |
| `snpolctl -p <plugin>` | Показать плагин |
| `snpolctl -p <plugin> -c spec` | Изменить параметр |
