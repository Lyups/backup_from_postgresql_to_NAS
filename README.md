# Скрипт резервного копирования баз данных PostgreSQL
# Версии для Linux и Windows

Этот проект содержит скрипты для создания резервных копий баз данных PostgreSQL и загрузки их на несколько NAS-устройства. Поддерживает два режима работы: создание текстовых дампов (`sql`) и создание бинарных архивов (`backup`).

## Файлы проекта

- `backup_psql.sh` - Linux версия (bash)
- `backup_psql.ps1` - Windows версия (PowerShell)

---

## Linux версия (backup_psql.sh)

### Настройка

#### 1. Переменные окружения

В начале скрипта настройте следующие переменные:

```bash
LOG_FILE="$PWD/logs/backupAll_dev_edit.log"
LOCAL_BACKUP_DIR="$PWD/local_backups"
DAYS_OLD=7
DB_NAMES=("fortest")
```

#### 2. NAS-настройки

```bash
# Сетевые шарды NAS
NAS_SHARES=(
    "//NAS1/backup_folder"
    "//NAS2/backup_folder"
    "//NAS3/backup_folder"
)

# Точки монтирования
MOUNT_POINTS=(
    "/mnt/NAS1"
    "/mnt/NAS2"
    "/mnt/NAS3"
)

# Файлы с учетными данными
CREDENTIAL_FILES=(
    "/root/.NAS1"
    "/root/.NAS2"
    "/root/.NAS3"
)
```

#### 3. Файлы учетных данных

Создайте файлы для каждого NAS в формате:
```
username=your_username
password=your_password
```

### Использование

```bash
# Создание .sql дампов
./backup_psql.sh sql

# Создание дампов в формате .backup
./backup_psql.sh backup
```

**Примечание:** В bash версии список баз данных задается в переменной `DB_NAMES` внутри скрипта и не может быть передан через параметры командной строки.

---

## Windows версия (backup_psql.ps1)

### Настройка

#### 1. Конфигурационные переменные

В начале скрипта настройте следующие переменные:

```powershell
# Пути к файлам и папкам
$LOG_FILE = "C:\backuper\logs\backupAll.log"
$LOCAL_BACKUP_DIR = "C:\backuper\local_backups"
$PG_DUMP_PATH = "C:\Postresql\bin\pg_dump.exe"
$DAYS_TO_KEEP = 1

# Файл с учетными данными PostgreSQL
$env:PGPASSFILE = "C:\backuper\credential\.pgpass"

# Список баз данных для бэкапа (по умолчанию)
[string[]]$DB_NAMES = @("test_base1", "test_base2", "test_base3")
```

#### 2. NAS-настройки

```powershell
# Сетевые шарды NAS
$NAS_SHARES = @(
    "\\NAS1\backup_folder",
    "\\NAS2\backup_folder",
    "\\NAS3\backup_folder"
)

# Файлы с учетными данными для NAS
$CREDENTIAL_FILES = @(
    "C:\backuper\credential\.nas1",
    "C:\backuper\credential\.nas2",
    "C:\backuper\credential\.nas3"
)
```

#### 3. Файлы учетных данных

##### PostgreSQL (.pgpass)
Создайте файл `C:\backuper\credential\.pgpass`:
```
localhost:5432:database_name:username:password
или localhost:5432:*:username:password
```

##### NAS учетные данные
Создайте файлы для каждого NAS в формате:
```
username=your_username
password=your_password
```

#### 4. Структура папок

Скрипт автоматически создаст следующие папки:
- `C:\backuper\logs\` - для лог-файлов
- `C:\backuper\local_backups\` - для локальных бэкапов
- `C:\backuper\credential\` - для файлов учетных данных

### Использование

#### Базовый запуск с дефолтными базами
```powershell
# Создание .sql дампов
.\backup_psql.ps1 -ACTION sql

# Создание дампов в формате .backup
.\backup_psql.ps1 -ACTION backup
```

#### Запуск с пользовательским списком баз
```powershell
# Создание .sql дампов для конкретных баз
.\backup_psql.ps1 -ACTION sql -DB_NAMES "db1","db2","db3"

# Создание .backup дампов для одной базы
.\backup_psql.ps1 -ACTION backup -DB_NAMES "production_db"
```

#### Для планировщика задач Windows
```powershell
# Создание .sql дампов
powershell.exe -File "C:\root\scripts\backupAll.ps1" -ACTION sql

# Создание .backup дампов
powershell.exe -File "C:\root\scripts\backupAll.ps1" -ACTION backup
```

---

## Общая функциональность

### Автоматическое создание папок
Обе версии автоматически создают все необходимые папки при запуске.

### Логирование
Все операции записываются в лог-файл с временными метками.

### Монтирование NAS
Скрипты автоматически монтируют и размонтируют NAS-устройства при копировании.

### Очистка старых файлов
После успешной загрузки на все NAS, локальные копии старше указанного количества дней автоматически удаляются.

### Обработка ошибок
Скрипты включают обработку прерываний и детальное логирование ошибок.

## Требования

### Linux версия
- Bash shell
- PostgreSQL с установленным `pg_dump`
- Доступ к сетевым шардам NAS
- Права на создание папок и файлов в указанных директориях

### Windows версия
- Windows PowerShell 5.0 или выше
- PostgreSQL с установленным `pg_dump.exe`
- Доступ к сетевым шардам NAS
- Права на создание папок и файлов в указанных директориях
