#!/bin/sh
# 5.10 启动后的一次性验收：内核 / ipv6 / BPF / 容器 / 移动硬盘 / 供电服务
echo "===== 1. 内核 ====="
uname -a
cat /proc/uptime | awk '{print "uptime(s) =", $1}'

echo "===== 2. ipv6（应为内建，不再有 ipv6 模块）====="
zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_IPV6(=|_)" | head -4
echo "-- lsmod ipv6 --"
lsmod 2>/dev/null | grep -w ipv6 || echo "  没有 ipv6 模块（内建，符合预期）"
echo "-- /sys/module/ipv6 --"
ls -d /sys/module/ipv6 2>/dev/null || echo "  /sys/module/ipv6 不存在（内建没有这个目录，正常）"
ip -6 addr show eth0 2>/dev/null | head -5

echo "===== 3. BPF / cgroup v2（podman 前提）====="
ls -l /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null || echo "  缺 bpf sysctl -> BPF_SYSCALL 没开"
zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_(BPF_SYSCALL|CGROUP_BPF|BPF_JIT|VXLAN|IPVLAN)="
mount | grep cgroup | head -3
podman --version 2>/dev/null || echo "  无 podman"

echo "===== 4. 网络 ====="
ip -br a | head -6

echo "===== 5. 移动硬盘 ====="
lsblk -o NAME,SIZE,MOUNTPOINT | grep -E "sd|mmcblk2" | head -8
df -h /mnt/usbdrive 2>/dev/null | tail -1

echo "===== 6. USB HUB 供电服务 ====="
systemctl is-enabled usb-hub-power.service 2>/dev/null
systemctl is-active usb-hub-power.service 2>/dev/null
tail -5 /var/log/usb-hub-power.log 2>/dev/null || echo "  暂无日志"

echo "===== 7. initramfs 启动日志（新脚本应能写出来）====="
tail -20 /mnt/sd_boot/logs/510-boot.log 2>/dev/null || echo "  510-boot.log 不存在"

echo "===== 8. 启动自检 guard ====="
tail -5 /mnt/sd_boot/logs/guard.log 2>/dev/null
grep -c . /proc/cmdline >/dev/null && echo "cmdline: $(cat /proc/cmdline)"
