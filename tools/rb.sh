#!/bin/sh
# 用 plink 在板子上执行一段命令（从文件读入，避免命令行转义问题）
# 用法： tools/rb.sh <命令文件>         # 批量执行脚本
#        tools/rb.sh -c '命令'          # 单条命令
#
# 入口自动选择：板子有 LAN / easytier(tun0) / tailscale 三个地址，经常只挂其中一两个
# （2026-11-20 就遇到 tailscale 掉、LAN 路由消失、只有 easytier 还通）。所以默认逐个
# ping，用第一个通的；显式给 KING_HOST 时只试它。
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+Klm23g2plO3ZcJtMjg71QXowQr7gxIFxQNqoXYA3Z"
DIR=$(dirname "$0")

if [ -n "${KING_HOST:-}" ]; then
	HOST=$KING_HOST
else
	HOST=""
	for h in 192.168.3.2 100.10.10.4 100.118.28.34; do
		if ping -c1 -W1 "$h" >/dev/null 2>&1; then
			HOST=root@$h
			break
		fi
	done
	[ -z "$HOST" ] && HOST=root@100.10.10.4
fi

if [ "$1" = "-c" ]; then
	tmp=$(mktemp)
	printf '%s\n' "$2" >"$tmp"
	"$DIR/plink.exe" -ssh -batch -pw fa -hostkey "$KEY" -m "$tmp" "$HOST"
	rc=$?
	rm -f "$tmp"
	exit $rc
fi

"$DIR/plink.exe" -ssh -batch -pw fa -hostkey "$KEY" -m "$1" "$HOST"
