#!/bin/sh
# 以指定的 U-Boot next 值重启板子，等待回来后报告结果
#   usage: tools/dbgboot.sh 510dbg
# 输出：回来后 uname -r / ub 打点 / 起 boot 日志
HOST=${KING_HOST:-root@192.168.3.2}
NEXT=${1:-510}
DIR=$(dirname "$0")
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+Klm23g2plO3ZcJtMjg71QXowQr7gxIFxQNqoXYA3Z"

r() { KING_HOST=$HOST "$DIR/rb.sh" -c "$1" 2>&1; }

t0=$(date +%s)
r "/usr/local/sbin/kb-envset next=$NEXT; sync; sleep 1; reboot -f" >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] reboot -> next=$NEXT"

# 等掉线（最多 30s）
for i in $(seq 1 10); do ping -c1 -W1 ${HOST#*@} >/dev/null 2>&1 || break; sleep 3; done

for i in $(seq 1 70); do
    if ping -c1 -W1 ${HOST#*@} >/dev/null 2>&1; then
        echo "[$(date +%H:%M:%S)] ping back after $(( $(date +%s)-t0 ))s"
        sleep 6
        for j in 1 2 3 4 5; do
            out=$(r 'uname -r; /usr/local/sbin/kb-envset show | grep -E "^ub=" || echo "ub=(none)"; ls -l /mnt/sd_boot/logs/510-boot.log 2>/dev/null || true')
            [ -n "$out" ] && { printf '%s\n' "$out"; exit 0; }
            sleep 5
        done
        echo "SSH 未通"
        exit 1
    fi
    sleep 5
done
echo "TIMEOUT: 板子未回来（$(( $(date +%s)-t0 ))s）"
exit 1
