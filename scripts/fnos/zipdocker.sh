#!/bin/bash
# Docker 目录备份；仅暂停名称包含 mysql 的运行中容器。
set -Eeuo pipefail
umask 077
SOURCE_DIR="/vol2/@team/docker"
OUTPUT_DIR="/vol2/@team/backup/docker"
TIMESTAMP=$(date +"%Y%m%d")
OUTPUT_FILE="docker-${TIMESTAMP}.tar.zst"
TMP_ROOT="${TMPDIR:-/tmp}"
PARTIAL=""
STOPPED_CONTAINERS=()
RESTORE_FAILED=0

restore_mysql() {
    local container
    RESTORE_FAILED=0
    for container in "${STOPPED_CONTAINERS[@]}"; do
            if ! docker start "$container" >/dev/null; then
            echo "错误：容器 $container 恢复失败，请立即手动检查！" >&2
            RESTORE_FAILED=1
        fi
    done
    if (( RESTORE_FAILED == 0 )); then
        STOPPED_CONTAINERS=()
    fi
    return "$RESTORE_FAILED"
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if ! restore_mysql; then rc=1; fi
    if [[ -n "$PARTIAL" && -f "$PARTIAL" ]]; then
        rm -f -- "$PARTIAL" || rc=1
    fi
    if (( rc != 0 )); then
        echo "备份未完整成功；旧正式备份未因本次失败而清理。" >&2
    fi
    echo "————————————执行完毕($(date +'%Y-%m-%d %H:%M'))————————————"
    exit "$rc"
}

echo "————————————执行开始($(date +'%Y-%m-%d %H:%M'))————————————"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for tool in docker tar zstd flock nice ionice mktemp date find sort; do
    command -v "$tool" >/dev/null || { echo "错误：缺少命令 $tool" >&2; exit 1; }
done
[[ -d "$SOURCE_DIR" ]] || { echo "错误：源目录不存在：$SOURCE_DIR" >&2; exit 1; }
# 固定锁文件保留，不删除，避免锁文件 inode 竞争。
exec 9>"$TMP_ROOT/zipdocker-backup.lock"
flock -n 9 || { echo "已有备份正在运行，本次跳过。" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# 先验证 Docker 可用，失败时不把它当作空列表。
RUNNING=$(docker ps --format '{{.Names}}')
while IFS= read -r container; do
    [[ -n "$container" && "$container" == *mysql* ]] || continue
    # 先记录，确保 docker stop 部分成功或被信号中断也会尝试恢复。
    STOPPED_CONTAINERS+=("$container")
    docker stop --timeout 60 "$container" >/dev/null
done <<< "$RUNNING"

PARTIAL=$(mktemp "$OUTPUT_DIR/.${OUTPUT_FILE}.partial.XXXXXX")
echo "开始备份：$SOURCE_DIR"
echo "输出文件：$OUTPUT_DIR/$OUTPUT_FILE"

# pipefail 确保 tar 失败不会被 zstd 成功掩盖。
# socket 为临时通信端点，可忽略该类提示；不忽略真正读取错误。
# GNU tar 创建归档时退出码 1 表示打包期间文件变化，按用户要求允许。
# 分别检查 tar/zstd 状态，不用 || true 吞掉真正错误。
set +e
nice -n 10 ionice -c 3 tar --warning=no-file-ignored --warning=no-file-changed -pc \
    -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")" \
    | nice -n 10 ionice -c 3 zstd -q -3 -T2 -f -o "$PARTIAL"
PIPE_RESULTS=("${PIPESTATUS[@]}")
set -e
if (( PIPE_RESULTS[1] != 0 )); then
    echo "错误：压缩失败，退出码 ${PIPE_RESULTS[1]}。" >&2
    exit 1
fi
if (( PIPE_RESULTS[0] == 1 )); then
    : # 已获允许忽略打包期间的文件变化，不输出额外提示。
elif (( PIPE_RESULTS[0] != 0 )); then
    echo "错误：tar 打包失败，退出码 ${PIPE_RESULTS[0]}。" >&2
    exit 1
fi
# 打包结束即恢复服务，避免校验大文件期间继续停库。
restore_mysql

nice -n 10 ionice -c 3 zstd -t -q -- "$PARTIAL"
# 同文件系统原子替换：校验失败不覆盖当天已有正式备份。
mv -f -- "$PARTIAL" "$OUTPUT_DIR/$OUTPUT_FILE"
PARTIAL=""
echo "备份完成：$OUTPUT_DIR/$OUTPUT_FILE"

# 只在打包、服务恢复、压缩校验均成功后清理旧备份。
CUTOFF=$(date -d "7 days ago" +%Y%m%d)
OLD_COUNT=0
while IFS= read -r file; do
    d="${file#docker-}"; d="${d%.tar.zst}"
    [[ "$d" =~ ^[0-9]{8}$ ]] || continue
    if [[ "$d" < "$CUTOFF" ]]; then
        rm -f -- "$OUTPUT_DIR/$file"
        OLD_COUNT=$((OLD_COUNT + 1))
    fi
done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'docker-*.tar.zst' -printf '%f\n' | sort)
echo "清理完成：删除 $OLD_COUNT 个过期备份。"
