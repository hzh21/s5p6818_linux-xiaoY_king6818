#!/bin/sh
# dmesg 实时落盘（5.10 崩溃取证用）
#
# 为什么需要：2026-11-20 两次 5.10 崩在 NULL deref，串口只吐出一行
# "Unable to handle kernel NULL pointer dereference" 就没了下文，
# 事后在 4.14 上完全拿不到 ESR/pc/lr/Call trace。
#
# 做法：
#   1. 启动分区（mmcblk2p1，独立 SD 卡）不经过 overlay，4.14 也能直接读；
#   2. 先用 dmesg -T 把【本次启动到目前为止】的全部历史刷盘并 sync，
#      这一步保证"崩之前已经发生过的事"一定在盘上；
#   3. 再用 dmesg -w -T 追新消息，stdbuf -oL 强制行缓冲
#      （直接重定向 stdout 是 stdio 全缓冲，崩溃时最后几 KB 正好全丢，
#        那正是我们要的东西），后台每 3s sync 一次把页缓存压下去。
#
# 不用 `while read < /dev/kmsg`：在 dash 下逐字节 read 会很快失败退出
# （2026-11-20 实测 crash-loop，status=1），见 git 历史。

LOG_BOOT=/mnt/sd_boot/logs/510-dmesg.log
LOG_ALT=/var/log/510-dmesg.log

LOG=$LOG_BOOT
i=0
while [ $i -lt 90 ]; do
	[ -d /mnt/sd_boot/logs ] && break
	i=$((i + 1))
	sleep 1
done
[ -d /mnt/sd_boot/logs ] || LOG=$LOG_ALT
mkdir -p "$(dirname "$LOG")" 2>/dev/null

printf '\n===== boot %s  kernel %s =====\n' \
	"$(date '+%F %T')" "$(uname -r)" >> "$LOG" 2>/dev/null

# 2) 历史全量刷盘
dmesg -T >> "$LOG" 2>/dev/null
sync

# 3) 追新：行缓冲 + 定期 sync
(
	while :; do
		sleep 3
		sync
	done
) &

exec stdbuf -oL -eL dmesg -w -T >> "$LOG" 2>/dev/null
