#!/bin/bash
# 给 5.10 内核树打 king6818 板级补丁
# 用法: bash apply-patches.sh <5.10 源码树根目录>
# CI 里和板子上跑的是同一份，方便先干跑验证。
set -e

K="${1:?用法: apply-patches.sh <kernel-tree>}"
D="$K/arch/arm64/boot/dts/nexell"
S="$K/drivers/net/ethernet/stmicro/stmmac"
RAW="https://raw.githubusercontent.com/hzh21/s5p6818_linux-xiaoY_king6818"
BR="refs/heads/ci/5.10-king6818"

# 板级 dts 与移植好的 gmac glue 驱动
curl -sSLf -o "$D/s5p6818-king6818.dts" \
	"$RAW/master/arch/arm64/boot/dts/nexell/s5p6818-king6818.dts"
curl -sSLf -o "$D/s5p6818-king6818-common.dtsi" \
	"$RAW/master/arch/arm64/boot/dts/nexell/s5p6818-king6818-common.dtsi"
curl -sSLf -o "$S/dwmac-nexell.c" "$RAW/$BR/ci/dwmac-nexell.c"

# 补丁 1：5.10 的 s5p6818.dtsi 已在顶层 include pinctrl，
#          common.dtsi 里 soc 内的那行会重复包含 -> 语法错，删掉
sed -i '/#include "s5p6818-pinctrl.dtsi"/d' "$D/s5p6818-king6818-common.dtsi"

# 补丁 2：5.10 把 SoC 节点改名 soc -> soc@0，
#          写 soc { } 会新建节点导致标签全部重复，必须同名合并
sed -i 's|^\tsoc {$|\tsoc@0 {|' "$D/s5p6818-king6818-common.dtsi"

# 补丁 3：重写 gmac0 节点，让 5.10 的 phylink 能真正 attach 到板载 PHY。
#
#   实测基准（板子上 4.14 正常工作时 dump 出来的活 DT）：
#     RTL8211E 挂在 MDIO 地址 4，snps,phy-addr = <4>，phy-mode = rgmii，
#     reset = gpio_e22 低有效，延时 0/10ms/30ms，MAC 节点下没有 fixed-link。
#
#   5.10 的三条硬性要求（对着 drivers/net/ethernet/stmicro/stmmac 核过）：
#     a) mdio 子节点必须带 compatible = "snps,dwmac-mdio"。
#        stmmac_platform.c:337 只会对带这个 compatible 的子节点置 mdio=true，
#        否则 mdio_bus_data 为 NULL，stmmac_mdio_register() 根本不注册总线，
#        PHY 从头到尾不会被 attach，snps,reset-gpios 也不会被脉冲复位。
#     b) MAC 节点必须有 phy-handle。5.10 的 stmmac_phy_setup() 把 MAC 节点
#        作为 fwnode 交给 phylink_create()，phylink 只会顺着 phy-handle 找
#        phy fwnode；没有它就没有 phydev，link_an_mode 停在 MLO_AN_PHY 却
#        无人可谈，MAC 速度恒为 UNKNOWN，RGMII 的 RX 时钟建立不起来
#        -> 表现就是 TX 计数正常、RX 恒为 0。
#     c) 复位用复数 snps,reset-gpios（stmmac_mdio.c:307 走
#        devm_gpiod_get_optional(dev, "snps,reset")），低有效 -> flag = 1。
#        单数的 snps,reset-gpio + snps,reset-active-low 一并保留，
#        这样同一个 dtb 在 4.14 的 BSP 驱动下也认得。
# 注：CI 的 ubuntu:20.04 容器里没有 python3，这里只用 printf + awk。
printf '%b\n' \
	'\t\tgmac0:ethernet@c0060000 {' \
	'\t\t\tpinctrl-names = "default";' \
	'\t\t\tpinctrl-0 = <&gmac_pins>;' \
	'' \
	'\t\t\tstatus = "okay";' \
	'\t\t\t#address-cells = <0x1>;' \
	'\t\t\t#size-cells = <0x0>;' \
	'' \
	'\t\t\tphy-mode = "rgmii";' \
	'\t\t\tphy-handle = <&ethernet_phy>;' \
	'\t\t\tsnps,phy-addr = <4>;' \
	'' \
	'\t\t\tsnps,reset-gpio = <&gpio_e 22 0>;' \
	'\t\t\tsnps,reset-active-low;' \
	'\t\t\tsnps,reset-gpios = <&gpio_e 22 1>;' \
	'\t\t\tsnps,reset-delays-us = <0 10000 30000>;' \
	'' \
	'\t\t\tmdio {' \
	'\t\t\t\tcompatible = "snps,dwmac-mdio";' \
	'\t\t\t\t#address-cells = <1>;' \
	'\t\t\t\t#size-cells = <0>;' \
	'' \
	'\t\t\t\tethernet_phy: ethernet-phy@4 {' \
	'\t\t\t\t\treg = <4>;' \
	'\t\t\t\t};' \
	'\t\t\t};' \
	'\t\t};' \
	> /tmp/gmac_block.txt

awk '
NR == FNR { blk = blk $0 "\n"; next }
index($0, "gmac0:ethernet@c0060000 {") { skip = 1; next }
skip && $0 == "\t\t};" { skip = 0; printf "%s", blk; next }
skip { next }
{ print }
' /tmp/gmac_block.txt "$D/s5p6818-king6818-common.dtsi" > /tmp/dts.new

if [ "$(grep -c 'phy-handle = <&ethernet_phy>;' /tmp/dts.new)" != "1" ]; then
	echo "FATAL: gmac0 rewrite failed" >&2
	exit 1
fi
mv /tmp/dts.new "$D/s5p6818-king6818-common.dtsi"

# 补丁 4：把 dtb 目标加进 nexell/Makefile
sed -i 's|^\ts5p6818-nanopim3.dtb$|\ts5p6818-nanopim3.dtb \\\n\ts5p6818-king6818.dtb|' \
	"$D/Makefile"

# 补丁 5：给 gmac glue 驱动加 Kconfig / Makefile 条目
if ! grep -q "DWMAC_NEXELL" "$S/Kconfig"; then
	printf 'config DWMAC_NEXELL\n\ttristate "Nexell S5P6818 dwmac support"\n\tdefault y\n\tdepends on OF && (STMMAC_PLATFORM || COMPILE_TEST)\n\thelp\n\t  Support for the DesignWare GMAC on Nexell S5P6818 SoCs.\n\n' > /tmp/kcfg.txt
	awk 'NR==FNR { blk = blk $0 "\n"; next }
	     /^config DWMAC_OXNAS$/ { printf "%s", blk }
	     { print }' /tmp/kcfg.txt "$S/Kconfig" > /tmp/Kconfig.new
	mv /tmp/Kconfig.new "$S/Kconfig"
fi
if ! grep -q "CONFIG_DWMAC_NEXELL" "$S/Makefile"; then
	awk '/CONFIG_DWMAC_OXNAS/ && !d {
		print
		print "obj-$(CONFIG_DWMAC_NEXELL)\t+= dwmac-nexell.o"
		d = 1
		next
	     }
	     { print }' "$S/Makefile" > /tmp/mk.new
	mv /tmp/mk.new "$S/Makefile"
fi

# 补丁 6（2026-11-21 移除，改为开关）：TLB 失效不再靠改 tlbflush.h。
#
#   原来这里用 awk 把 __flush_tlb_range() 整个换成了 flush_tlb_mm()，只堵住
#   "按范围失效"一条路。真正的原因是这颗 SoC 的 CCI400 只支持 DVMv7 协议
#   （仅 ARMv7），ARMv8 的 TLBI ...IS 是 inner-shareable 广播，跨 cluster
#   传递要靠 DVM 消息，DVMv7 送不对。AMBA AXI/ACE C12.4/12.6 的两条硬约束：
#     1) ASID 高 8 位必须为 0，否则消息被静默丢弃
#     2) "TLB Invalidation by address range" 整类不可靠
#   厂商在 5.10 里其实把 workaround 全写好了（tlbflush.h 4 处 +
#   context.c 3 处），由 CONFIG_ARM64_WORKAROUND_CCI400_DVMV7 统一开关，
#   但它默认是关的 —— 等于只留了 flush_tlb_mm 一处，flush_tlb_page /
#   __flush_tlb_range / flush_tlb_kernel_range / __flush_tlb_kernel_pgtable
#   四条路全是裸的 vale1is/vaale1is。
#
#   现在改成在 CI 的 Configure 步骤里直接打开该配置项（见
#   .github/workflows/5.10-king6818.yml），厂商代码零改动、覆盖面完整。
#   这里只做核对：那几处 #ifdef 必须还在，上游改了就报错退出。

# 补丁 7：把 ARM64_WORKAROUND_CCI400_DVMV7 从 PA 位宽的 choice 里挪出来。
#
#   厂商把这一项写进了 "Physical address space size" 那个 choice 内部：
#       choice
#           prompt "Physical address space size"
#           default ARM64_PA_BITS_48
#       config ARM64_WORKAROUND_CCI400_DVMV7     <-- 成了 choice 的成员
#       config ARM64_PA_BITS_48
#       ...
#       endchoice
#
#   choice 的语义是"这一组里只能选一个"，所以 `scripts/config --enable` 会把它
#   和 PA_BITS_48 同时置 y，形成非法状态；紧接着 `make olddefconfig` 按 choice
#   的 default 又把它丢回 n。实测 run 44858681648 的日志正是如此：
#       ./scripts/config --enable CONFIG_ARM64_WORKAROUND_CCI400_DVMV7
#       ...
#       # CONFIG_ARM64_WORKAROUND_CCI400_DVMV7 is not set
#
#   这也解释了为什么这个 workaround 从 4.14 一路到 5.10 都没人启用过 ——
#   在 menuconfig 里根本选不上，7 处 #ifdef 等于永远走不进 else 分支。
#
#   做法：整段搬到 choice 之前，变成独立的 bool。PA 位宽那个 choice 只剩
#   PA_BITS_48，行为和原来完全一致。
KC="$K/arch/arm64/Kconfig"
CCIBLK=/tmp/cciblk.txt
awk '
	/^config ARM64_WORKAROUND_CCI400_DVMV7$/ { grab = 1 }
	grab && /^config / && $0 != "config ARM64_WORKAROUND_CCI400_DVMV7" { exit }
	grab { print }
' "$KC" > "$CCIBLK"
if [ "$(wc -l < "$CCIBLK")" -lt 8 ] || ! grep -q 'depends on SMP' "$CCIBLK"; then
	echo "FATAL: 抠 ARM64_WORKAROUND_CCI400_DVMV7 段落失败" >&2
	exit 1
fi
# 先从 choice 里删掉
awk '
	/^config ARM64_WORKAROUND_CCI400_DVMV7$/ { skip = 1; next }
	skip && /^config / { skip = 0 }
	skip { next }
	{ print }
' "$KC" > /tmp/kconfig.nb
# 再插到 PA 位宽 choice 之前（整个文件读进内存，按两行上下文定位）
if ! awk -v blk="$CCIBLK" '
	BEGIN { while ((getline l < blk) > 0) b = b l "\n"; close(blk) }
	{ lines[NR] = $0 }
	END {
		for (i = 1; i <= NR; i++) {
			if (!done && lines[i] == "choice" &&
			    lines[i + 1] ~ /prompt "Physical address space size"/) {
				printf "%s", b
				done = 1
			}
			print lines[i]
		}
		if (!done) exit 2
	}
' /tmp/kconfig.nb > /tmp/kconfig.new; then
	echo "FATAL: 找不到 PA 位宽 choice 的插入点" >&2
	exit 1
fi
mv /tmp/kconfig.new "$KC"
# 复核：workaround 的 config 行必须出现在 PA 位宽 prompt 之前
L1=$(grep -n '^config ARM64_WORKAROUND_CCI400_DVMV7$' "$KC" | cut -d: -f1)
L2=$(grep -n 'prompt "Physical address space size"' "$KC" | cut -d: -f1)
if [ -z "$L1" ] || [ -z "$L2" ] || [ "$L1" -ge "$L2" ]; then
	echo "FATAL: ARM64_WORKAROUND_CCI400_DVMV7 仍在 PA 位宽 choice 内 ($L1 vs $L2)" >&2
	exit 1
fi
echo "--- Kconfig 补丁核对：workaround 行 $L1 < PA choice 行 $L2 ---"

TLB="$K/arch/arm64/include/asm/tlbflush.h"
CTX="$K/arch/arm64/mm/context.c"
n_tlb=$(grep -c 'CONFIG_ARM64_WORKAROUND_CCI400_DVMV7' "$TLB" || true)
if [ "$n_tlb" != "4" ]; then
	echo "FATAL: tlbflush.h 里 CCI400 workaround 有 $n_tlb 处，应为 4" >&2
	exit 1
fi
if [ "$(grep -c 'CONFIG_ARM64_WORKAROUND_CCI400_DVMV7' "$CTX" || true)" != "3" ]; then
	echo "FATAL: context.c 里 CCI400 workaround 不是 3 处" >&2
	exit 1
fi
if ! grep -q '^config ARM64_WORKAROUND_CCI400_DVMV7' "$K/arch/arm64/Kconfig"; then
	echo "FATAL: Kconfig 里没有 ARM64_WORKAROUND_CCI400_DVMV7" >&2
	exit 1
fi
echo '--- TLB workaround 核对（靠配置项驱动，本脚本不再改内核代码）---'
grep -n 'CONFIG_ARM64_WORKAROUND_CCI400_DVMV7' "$TLB" "$CTX"

echo '--- dtb Makefile ---'
cat "$D/Makefile"
echo '--- dts 补丁核对（gmac0 最终形态：应有 phy-handle / snps,dwmac-mdio，不应有 fixed-link）---'
sed -n '/gmac0:ethernet@c0060000/,/^\t\t};/p' "$D/s5p6818-king6818-common.dtsi"
echo '--- 关键点 ---'
grep -nE 'soc@0 \{|gmac0:|fixed-link|snps,dwmac-mdio|phy-handle|phy-addr|reset-gpios' \
	"$D/s5p6818-king6818-common.dtsi" | head
echo '--- 驱动接入核对 ---'
grep -n "DWMAC_NEXELL" "$S/Kconfig" "$S/Makefile"
wc -l "$S/dwmac-nexell.c"
grep -n 'nexell,s5p6818-gmac' "$S/dwmac-nexell.c"
