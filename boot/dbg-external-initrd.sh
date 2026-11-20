#!/bin/sh
# 定义一个「带外部 initrd」的启动槽 boot_510dbg，用来在不重编内核的前提下
# 反复替换 initramfs 里的 /init 做实验。
#
#   next=510dbg  ->  U-Boot 跑 boot_510dbg：Image.510 + kg-initrd.gz + dtb
#   失败自动回 4.14（ksel 的 fallback）
#
# ub 打点同 boot_510：0/1/2 内核加载/4 initrd 加载/3 即将 booti/9 booti 返回
set -e

ENV=/usr/local/sbin/kb-envset

$ENV boot_510dbg='setenv bootargs "${bootargs_510}"; setenv ub 0; saveenv; setenv kernel Image.510; setenv dtb_name king6818-510.dtb; setenv initrd_name kg-initrd.gz; if ext4load mmc ${rootdev}:${bootpart} ${loadaddr} ${kernel}; then setenv ub 2; saveenv; if ext4load mmc ${rootdev}:${bootpart} ${initrd_addr} ${initrd_name}; then setenv initrd_size 0x${filesize}; setenv ub 4; saveenv; if ext4load mmc ${rootdev}:${bootpart} ${dtb_addr} ${dtb_name}; then setenv ub 3; saveenv; booti ${loadaddr} ${initrd_addr}:${initrd_size} ${dtb_addr}; setenv ub 9; saveenv; fi; fi; fi'

echo "== boot_510dbg =="
$ENV show | grep '^boot_510dbg='
$ENV -u ub 2>/dev/null || true
echo "== 外部 initrd 文件 =="
ls -l /mnt/sd_boot/kg-initrd.gz 2>/dev/null || echo "kg-initrd.gz 缺失"
echo "== 内核 =="
ls -l /mnt/sd_boot/Image.510
