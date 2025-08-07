# Для планировщика задач:
# powershell.exe -File "C:\root\scripts\backupAll.ps1" -ACTION backup
# powershell.exe -File "C:\root\scripts\backupAll.ps1" -ACTION sql

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("sql", "backup")]
    [string]$ACTION,
    [string[]]$DB_NAMES = @("test_base1", "test_base2", "test_base3")
)
# Установка правильной кодировки для всего скрипта
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$scriptPID = $PID
$LOG_FILE = "C:\backuper\logs\backupAll.log"
$LOCAL_BACKUP_DIR = "C:\backuper\local_backups"
$BACKUP_FOLDER = "$(Get-Date -Format 'yyyy-MM-dd')_backupAll_$ACTION"
$BACKUP_PATH = Join-Path -Path $LOCAL_BACKUP_DIR -ChildPath $BACKUP_FOLDER
$PG_DUMP_PATH = "C:\Postresql\bin\pg_dump.exe"
$DAYS_TO_KEEP = 1

# .pgpass
$env:PGPASSFILE = "C:\backuper\credential\.pgpass"
if (-not (Test-Path $env:PGPASSFILE)) {
    Write-Host "КРИТИЧЕСКАЯ ОШИБКА: файл .pgpass не найден: $($env:PGPASSFILE)"
    exit 1
}

# NAS shares
$NAS_SHARES = @(
    "\\NAS1\backup_folder",
    "\\NAS2\backup_folder",
    "\\NAS3\backup_folder"
)

# Credential files for NAS shares
$CREDENTIAL_FILES = @(
    "C:\backuper\credential\.nas1",
    "C:\backuper\credential\.nas2",
    "C:\backuper\credential\.nas3"
)

# --- MKDIR's ---
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $LOG_FILE) -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Force -Path $LOCAL_BACKUP_DIR -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "КРИТИЧЕСКАЯ ОШИБКА СОЗДАНИЯ ДИРЕКТОРИЙ: $_"
    exit 1
}

# --- Logs and info ---
function log {
    param([string]$message)
    $logEntry = "$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss') - $message"
    try {
        # Используем UTF-8 без BOM
        $logEntry | Out-File -FilePath $LOG_FILE -Append -Encoding utf8
        Write-Output $logEntry
    }
    catch {
        Write-Error "Ошибка записи в лог: $_"
    }
}

function start_info {
    log "----------------------------------------"
    log "Старт скрипта с PID $scriptPID"
}

function finish_info {
    log "Конец скрипта с PID $scriptPID"
    log "========================================"
}

function mount_nas {
    param($share, $credFile)
    
    if (-not (Test-Path $credFile)) {
        log "Файл учетных данных отсутствует: $credFile"
        return $false
    }
    
    $content = Get-Content $credFile
    $username = ($content | Where-Object { $_ -match 'username=(.+)' }).Split('=')[1]
    $password = ($content | Where-Object { $_ -match 'password=(.+)' }).Split('=')[1]

    if (-not $username -or -not $password) {
        log "Ошибка формата в файле: $credFile"
        return $false
    }

    $securePass = ConvertTo-SecureString $password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($username, $securePass)

    try {
        log "Монтирую $share ..."
        New-SmbMapping -RemotePath $share -Credential $cred -ErrorAction Stop | Out-Null
        log "Успешно смонтировано: $share"
        return $true
    }
    catch {
        log "!!! Ошибка монтирования: $share - $($_.Exception.Message)"
        return $false
    }
}

function umount_nas {
    param($share)
    try {
        log "Размонтирую $share ..."
        Remove-SmbMapping -RemotePath $share -Force -ErrorAction Stop
        log "Успешно размонтировано: $share"
    }
    catch {
        log "!!! Ошибка размонтирования: $share - $($_.Exception.Message)"
    }
}

function create_local_backup {
    try {
        New-Item -ItemType Directory -Path $BACKUP_PATH -Force -ErrorAction Stop | Out-Null
        log "Создана папка $BACKUP_PATH"
    }
    catch {
        log "!!! ОШИБКА СОЗДАНИЯ ПАПКИ: $BACKUP_PATH - $($_.Exception.Message)"
        throw
    }
    
    log "Создаю локальные резервные копии баз данных в $BACKUP_PATH ..."
    
    foreach ($db_name in $DB_NAMES) {
        $TIMESTAMP = Get-Date -Format "yyyy-MM-dd"
        if ($ACTION -eq "sql") {
            $BACKUP_FILE = Join-Path $BACKUP_PATH "$db_name-$TIMESTAMP.sql"
            log "Создаю SQL-дамп для $db_name..."
        }
        else {
            $BACKUP_FILE = Join-Path $BACKUP_PATH "$db_name--$TIMESTAMP.backup"
            log "Создаю бинарный бэкап для $db_name..."
        }
        
        try {
            & $PG_DUMP_PATH --username postgres --dbname $db_name --file $BACKUP_FILE 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    log "ОШИБКА \"$PG_DUMP_PATH\": $($_.Exception.Message)"
                } else {
                    log $_
                }
            }
            
            if ($LASTEXITCODE -eq 0) {
                log "Бэкап '$db_name' успешно создан: $BACKUP_FILE"
                $global:backupSuccess = $true
            }
            else {
                log "!!! ОШИБКА при создании бэкапа '$db_name' (код $LASTEXITCODE)"
                $global:backupSuccess = $false
            }
        }
        catch {
            log "!!! КРИТИЧЕСКАЯ ОШИБКА при создании бэкапа '$db_name': $($_.Exception.Message)"
            $global:backupSuccess = $false
        }
    }
}

function upload_to_all_nas {
    $successCount = 0
    $totalNAS = $NAS_SHARES.Count
    
    for ($i = 0; $i -lt $totalNAS; $i++) {
        $share = $NAS_SHARES[$i]
        $credFile = $CREDENTIAL_FILES[$i]
        $copyNum = $i + 1
        
        if (mount_nas $share $credFile) {
            # Имя удалённой папки (без пути диска)
            $remoteDirName = Split-Path $share -Leaf
            # Целевой путь — корневая папка шары + имя бэкапа
            $destPath = Join-Path $share $BACKUP_FOLDER
            
            log "Копирую папку '$BACKUP_PATH' в $destPath (копирование $copyNum из $totalNAS) ..."
            
            try {
                Copy-Item -Path $BACKUP_PATH -Destination $destPath -Recurse -Force -ErrorAction Stop
                log "Папка успешно скопирована в $destPath (копирование $copyNum из $totalNAS)"
                $successCount++
                $global:uploadSuccess = $true
            }
            catch {
                log "!!! ОШИБКА копирования в $destPath (копирование $copyNum из $totalNAS): $($_.Exception.Message)"
                $global:uploadSuccess = $false
            }
            finally {
                umount_nas $share
            }
        }
    }
    
    if ($successCount -eq $totalNAS) {
        log "Бэкапы загружены на все NAS"
        
        # Удаляем папки старше $DAYS_TO_KEEP дня
        $oldBackups = Get-ChildItem $LOCAL_BACKUP_DIR -Directory | Where-Object {
            $_.CreationTime -lt (Get-Date).AddDays(-$DAYS_TO_KEEP)
        }
        
        if ($oldBackups) {
            log "Удаляю старые локальные копии..."
            $oldBackups | Remove-Item -Recurse -Force
            log "Удалено $($oldBackups.Count) старых бэкапов"
        }
        else {
            log "Нет папок для удаления."
        }
    }
    else {
        log "Не все NAS доступны! Локальные копии НЕ удаляются."
    }
}

# --- trap ---
trap {
    log "ПРЕРЫВАНИЕ! Аварийное завершение работы..."
    log "Последняя ошибка: $($_.Exception.Message)"
    finish_info
    exit 1
}

# --- main block ---
try {
    start_info
    create_local_backup
    
    if (-not $global:backupSuccess) {
        log "!!! СОЗДАНИЕ БЭКАПОВ ЗАВЕРШИЛОСЬ С ОШИБКАМИ"
    }
    
    upload_to_all_nas
    
    if (-not $global:uploadSuccess) {
        log "!!! ЗАГРУЗКА НА NAS ЗАВЕРШИЛАСЬ С ОШИБКАМИ"
    }
    
    if ($global:backupSuccess -and $global:uploadSuccess) {
        log "СКРИПТ УСПЕШНО ЗАВЕРШЕН"
    }
    else {
        log "СКРИПТ ЗАВЕРШЕН С ОШИБКАМИ"
        exit 1
    }
}
catch {
    log "!!! НЕПЕРЕХВАЧЕННАЯ ОШИБКА: $($_.Exception.Message)"
    exit 1
}
finally {
    finish_info
}