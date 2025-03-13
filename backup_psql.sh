#!/bin/bash

ACTION="$1"

LOG_FILE="$PWD/logs/backupAll_dev_edit.log"
LOCAL_BACKUP_DIR="$PWD/local_backups"
DAYS_OLD=7
DB_NAMES=("fortest")

BACKUP_FOLDER="backup_${ACTION}_$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_PATH="$LOCAL_BACKUP_DIR/$BACKUP_FOLDER"

mkdir -p "$(dirname "$LOG_FILE")" "$LOCAL_BACKUP_DIR"

# args for cifs
NAS_SHARES=(
    "//NAS1/backup_folder"
    "//NAS2/backup_folder"
    "//NAS3/backup_folder"
)  

MOUNT_POINTS=(
    "/mnt/NAS1"
    "/mnt/NAS2"
    "/mnt/NAS3"
)  

CREDENTIAL_FILES=(
    "/root/.NAS1"
    "/root/.NAS2"
    "/root/.NAS3"
)

# trap
trap "log 'Прерывание! Завершаю ...'; exit 1" SIGINT

# info 
usage() {
    echo "Использование: $0 <ACTION>"
    echo "  <ACTION> - действие: sql или backup"
    exit 1
}

if [ "$#" -ne 1 ]; then
    echo "!!! Ошибка: Неверное количество аргументов!"
    usage
fi

log() {
    echo "$(date '+%d-%m-%Y %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

start_info() {
    log "----------------------------------------"
    log "Старт скрипта с PID $$"
}

finish_info() {
    log "Конец скрипта с PID $$"
}

# Main functions
mount_nas() {
    local index="$1"
    local share="${NAS_SHARES[$index]}"
    local mount_point="${MOUNT_POINTS[$index]}"
    local cred_file="${CREDENTIAL_FILES[$index]}"

    if [ ! -f "$cred_file" ]; then
        log "Файл учетных данных отсутствует: $cred_file"
        return 1
    fi

    log "Монтирую $share в $mount_point ..."
    mkdir -p "$mount_point"
    mount -t cifs -o credentials="$cred_file" "$share" "$mount_point"

    if [ $? -eq 0 ]; then
        log "Успешно смонтировано: $share"
        return 0
    else
        log "!!! Ошибка монтирования: $share"
        return 1
    fi
}

umount_nas() {
    local index="$1"
    local mount_point="${MOUNT_POINTS[$index]}"

    log "Размонтирую $mount_point ..."
    umount "$mount_point"

    if [ $? -eq 0 ]; then
        log "Успешно размонтировано: $mount_point"
    else
        log "!!! Ошибка размонтирования: $mount_point"
    fi
}

create_local_backup() {
    mkdir -p "$BACKUP_PATH" && log "Создаю папку $BACKUP_PATH"
    log "Создаю локальные резервные копии баз данных в $BACKUP_PATH ..."

    for db_name in "${DB_NAMES[@]}"; do
        TIMESTAMP=$(date "+%Y-%m-%d")
        if [ "$ACTION" == "sql" ]; then
            BACKUP_FILE="$BACKUP_PATH/$db_name-$TIMESTAMP.sql"
            pg_dump --username admuser --dbname "$db_name" > "$BACKUP_FILE" 2>> "$LOG_FILE"
        else
            BACKUP_FILE="$BACKUP_PATH/$db_name--$TIMESTAMP.backup"
            pg_dump --username admuser -Fc --dbname "$db_name" > "$BACKUP_FILE" 2>> "$LOG_FILE"
        fi

        if [ $? -eq 0 ]; then
            log "Бэкап '$db_name' создан: $BACKUP_FILE"
        else
            log "!!! Ошибка при создании бэкапа '$db_name'!"
        fi
    done
}

upload_to_all_nas() {
    local success_count=0
    local total_nas="${#NAS_SHARES[@]}"

    for i in "${!NAS_SHARES[@]}"; do
        mount_nas "$i" || continue

        local mount_point="${MOUNT_POINTS[$i]}"
        log "Копирую папку '$BACKUP_PATH' в $mount_point ..."

        cp -r "$BACKUP_PATH" "$mount_point" 2>&1 | tee -a "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log "Папка успешно скопирована в $mount_point"
            ((success_count++))
        else
            log "!!! Ошибка копирования в $mount_point!"
        fi

        umount_nas "$i"
    done

    if [ "$success_count" -eq "$total_nas" ]; then
        log "Бэкапы загружены на все NAS"
        
        OLD_BACKUPS=$(find "$LOCAL_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime $DAYS_OLD)
        
        if [ -n "$OLD_BACKUPS" ]; then
            log "Удаляю старые локальные копии..."
            find "$LOCAL_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime $DAYS_OLD -exec rm -rf {} \;
        else
            log "Нет папок для удаления."
        fi
    else
        log "Не все NAS доступны! Локальные копии НЕ удаляются."
    fi
}

# Logic
case "$ACTION" in
    sql|backup)
        start_info
        create_local_backup
        upload_to_all_nas
        finish_info
        ;;
    *)
        echo "!!! Ошибка: Неверное действие '$ACTION'"
        usage
        ;;
esac