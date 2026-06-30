#!/bin/bash
# =============================================================================
# Script: rsync_sync.sh
# Description: 将当前目录同步到多台远端主机的 /root/huize 目录
# Author: AI Assistant
# =============================================================================

set -euo pipefail

HOSTS=(
    192.168.0.2
    192.168.0.3
    192.168.0.4
    192.168.0.5
)

SOURCE_DIR="${1:-$(pwd)}"
DEST_DIR="/root/huize"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[ERROR] 源目录不存在: $SOURCE_DIR"
    exit 1
fi

if ! command -v rsync &>/dev/null; then
    echo "[ERROR] 未找到 rsync，请先安装 rsync"
    exit 1
fi

echo "开始同步:"
echo "  源目录: $SOURCE_DIR/"
echo "  目标目录: $DEST_DIR"
echo "  目标主机: ${HOSTS[*]}"
echo ""

for host in "${HOSTS[@]}"; do
    echo "[INFO] 同步到 $host ..."
    rsync -avz --progress \
        --exclude '.git/' \
        --exclude '.DS_Store' \
        -e ssh \
        "$SOURCE_DIR/" \
        "root@${host}:${DEST_DIR}/"
    echo "[INFO] $host 同步完成"
    echo ""
done

echo "全部同步完成"