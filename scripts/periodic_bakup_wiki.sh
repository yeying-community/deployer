#!/usr/bin/env bash
# this script is used to bakup wiki files
# haiqinma - 20251029 - first version
# haiqinma - 20251102 - compress backup files

set -u
set -o pipefail

LOGFILE_PATH="/var/log"
LOGFILE_NAME="periodic-bakup-wiki.log"
LOGFILE="$LOGFILE_PATH/$LOGFILE_NAME"
if [[ ! -d  "$LOGFILE_PATH" ]]
then
    mkdir -p "$LOGFILE_PATH"
fi


touch "$LOGFILE"

filesize=$(stat -c "%s" "$LOGFILE" )
if [[ "$filesize" -ge 1048576 ]]
then
    echo -e "clear old logs at $(date) to avoid log file too big" > "$LOGFILE"
fi


can_ssh_login() {
    local login_user="$1"
    local login_host="$2"

    if [[ -z "$login_user" || -z "$login_host" ]]; then
        echo "ERRROR: login user and ip address are necessary" >&2
        return 1
    fi

    ssh -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o PreferredAuthentications=publickey \
        "${login_user}@${login_host}" true &>/dev/null

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}


index=1
echo -e "\nstep $index -- This is the begining of bakup wiki. [$(date)] " | tee -a "$LOGFILE"

REMOTE_USER="root"
WIKI_HOST="159.138.36.164"
if can_ssh_login "${REMOTE_USER}" "${WIKI_HOST}"; then
    echo -e "the ${WIKI_HOST} could be ssh within 10 seconds"  | tee -a "$LOGFILE"
else
    echo -e "ERROR! the host ${WIKI_HOST} could not be ssh within 10 seconds right now [$(date)]"  | tee -a "$LOGFILE"
    exit 1
fi

index=$((index+1))
echo -e "\nstep $index -- check compress file exist or not" | tee -a "$LOGFILE"
COMPRESS_FILE="/root/code/yeying-tool/script/compress_file.sh"
flag_compress_file=$(ssh "${REMOTE_USER}@${WIKI_HOST}" 'test -e ${COMPRESS_FILE}' )
if [ "${flag_compress_file}" ]; then
    echo -e "there is no script($COMPRESS_FILE) to compress file"
    exit 2
fi


index=$((index+1))
echo -e "\nstep $index -- clean old bakup files" | tee -a "$LOGFILE"
KEEP_NUMBER=7
LOCAL_BACKUP_DIRECTORY="/root/bak/bak_wiki/"
if [ ! -d "$LOCAL_BACKUP_DIRECTORY" ]; then
    echo "directory is used to bakup wiki $LOCAL_BACKUP_DIRECTORY does no exist！" | tee -a "$LOGFILE"
    exit 3
fi

BACKUP_DIRS_COUNT=$(find "$LOCAL_BACKUP_DIRECTORY" -maxdepth 1 -type d -name "backup*" | wc -l)
if [ "$BACKUP_DIRS_COUNT" -gt "$KEEP_NUMBER" ]; then
    echo "there are many backup files, clear the files $KEEP_NUMBER days ago" | tee -a "$LOGFILE"
    find "$LOCAL_BACKUP_DIRECTORY" -maxdepth 1 -type d -name "backup*" -mtime +7 -exec rm -rf {} \;
fi


backup_directory_name="backup"$(date +%Y%m%d-%H%M%S)
index=$((index+1))
echo -e "\nstep $index -- backup wiki files" | tee -a "$LOGFILE"
local_backup_wiki=${LOCAL_BACKUP_DIRECTORY}/${backup_directory_name}/wiki
mkdir -p "${local_backup_wiki}"
WIKI_NEED_BACKUP=(
    "/root/code/yeying-tool/tool/bookstack/data/storage"
    "/root/code/yeying-tool/tool/bookstack/data/uploads"
    "/root/code/yeying-tool/tool/bookstack/packages"
    "/root/code/yeying-tool/tool/bookstack/.env"
)
for item in "${WIKI_NEED_BACKUP[@]}"; do
    echo "bakup wiki files: ${item}" | tee -a "$LOGFILE"
    type_backup="directory"
    if [[ "$item" == *env ]]; then
        local_dest="${local_backup_wiki}/env"
        type_backup="file"
    elif [[ "$item" == *data* ]]; then
        local_dest="${local_backup_wiki}/data"
        mkdir -p "${local_dest}"
    else
        local_dest="${local_backup_wiki}"
    fi
    remote_directory=$(dirname "$item")
    remote_name=$(basename "$item")

    if [[ "$type_backup" == file ]]; then
        if ! scp -r "${REMOTE_USER}@${WIKI_HOST}:${item}" "${local_dest}" ; then
            echo "ERROR! Failed to copy wiki file $item" | tee -a "$LOGFILE"
        fi
    else
        ssh "${REMOTE_USER}@${WIKI_HOST}" "bash ${COMPRESS_FILE} ${item}"
        sleep 2
        if ! scp -r "${REMOTE_USER}@${WIKI_HOST}:${remote_directory}/${remote_name}-*.tar.gz" "${local_dest}" ; then
            echo "ERROR! Failed to copy wiki directory $item compressed file" | tee -a "$LOGFILE"
        fi
        ssh "${REMOTE_USER}@${WIKI_HOST}" "rm -f ${remote_directory}/${remote_name}-*.tar.gz"
    fi
done


index=$((index+1))
echo -e "\nstep $index -- backup mysql files" | tee -a "$LOGFILE"
local_backup_mysql=${LOCAL_BACKUP_DIRECTORY}/${backup_directory_name}/mysql
mkdir -p "${local_backup_mysql}"
MYSQL_NEED_BACKUP=(
    "/root/code/yeying-tool/middleware/mysql/data"
    "/root/code/yeying-tool/middleware/mysql/.env"
)
for item in "${MYSQL_NEED_BACKUP[@]}"; do
    echo "bakup mysql files: ${item}" | tee -a "$LOGFILE"
    type_backup="directory"
    if [[ "$item" == *env ]]; then
        local_dest="${local_backup_mysql}/env"
        type_backup="file"
    else
        local_dest="${local_backup_mysql}"
    fi
    remote_directory=$(dirname "$item")
    remote_name=$(basename "$item")

    if [[ "$type_backup" == file ]]; then
        if ! scp -r "${REMOTE_USER}@${WIKI_HOST}:${item}" "${local_dest}" ; then
            echo "ERROR! Failed to copy mysql file $item" | tee -a "$LOGFILE"
        fi
    else
        ssh "${REMOTE_USER}@${WIKI_HOST}" "bash ${COMPRESS_FILE} ${item}"
        sleep 2
        if ! scp -r "${REMOTE_USER}@${WIKI_HOST}:${remote_directory}/${remote_name}-*.tar.gz" "${local_dest}" ; then
            echo "ERROR! Failed to copy mysql directory $item compressed file" | tee -a "$LOGFILE"
        fi
        ssh "${REMOTE_USER}@${WIKI_HOST}" "rm -f ${remote_directory}/${remote_name}-*.tar.gz"
    fi
done


echo -e "\nThis is the end of process wiki bakup operation. ====$(date)====" | tee -a "$LOGFILE"