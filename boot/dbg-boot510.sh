#!/bin/sh
# 给 boot_510 加「进度打点」：U-Boot 每完成一步就把自己的进度写进 env，
# 这样即使内核当场死掉、没有串口，也能在随后回到 4.14 时用 kb-envset 读出
# U-Boot 究竟走到哪一步。
#
#   ub=0  boot_510 开始执行
#   ub=1  准备加载内核
#   ub=2  内核 ext4load 成功  -> 25.8MB 的文件 U-Boot 能读
#   ub=3  dtb 也加载成功，即将 booti
#   ub=9  booti 返回了（失败）-> 内核根本没被启动
#   若 ub 停在 3 且没有 9：booti 成功、控制权交给内核，问题在内核侧
#
# 顺带把打点时刻的 ksel/sel 也记下来，便于判断回退路径。
set -e

ENV=/usr/local/sbin/kb-envset

$ENV boot_510='setenv ub 0; saveenv; setenv bootargs "${bootargs_510}"; setenv kernel Image.510; setenv dtb_name king6818-510.dtb; setenv ub 1; saveenv; if ext4load mmc ${rootdev}:${bootpart} ${loadaddr} ${kernel}; then setenv ub 2; saveenv; if ext4load mmc ${rootdev}:${bootpart} ${dtb_addr} ${dtb_name}; then setenv ub 3; saveenv; booti ${loadaddr} - ${dtb_addr}; setenv ub 9; saveenv; fi; fi'

echo "== 写回后的 boot_510 =="
$ENV show | grep '^boot_510='
$ENV -u ub 2>/dev/null || true
echo "== env 总字节数（上限 16384） =="
$ENV show | wc -c
