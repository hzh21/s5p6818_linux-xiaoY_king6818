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

# 补丁 6：S5P6818 上 TLBI by VA 跨 CPU cluster 不可靠
#
#   flush_tlb_mm() 里厂商早就留了 workaround（CONFIG_SMP &&
#   CONFIG_ARCH_S5P6818 时直接 flush_tlb_all()），但 __flush_tlb_range()
#   是上游原版，仍然逐页发 vae1is/vale1is。
#
#   实测（Cortex-A53 r0p3 / 8 核）：mprotect(PROT_READ) 返回后再过 20ms，
#   其他核写同一页仍然成功——5.10 失效率 89%，4.14 只有 0.06%
#   （4.14 开了 KPTI，每次 trap 都切 TTBR0，把同一缺陷掩盖了）。
#   页数达到 MAX_TLBI_OPS(512) 时走 flush_tlb_mm，失效率立刻归零，
#   精确坐实是"范围失效路径没生效"。
#
#   glibc 的堆保护、V8 的 JIT W^X 全都依赖 mprotect 语义，失效即表现为
#   随机 SIGSEGV 与 heap corruption。这里让范围失效一律委托 flush_tlb_mm()。
#
#   注：CI 的 ubuntu:20.04 容器没有 python3，这里只用 awk 做整函数替换。
TLB="$K/arch/arm64/include/asm/tlbflush.h"
if ! grep -q 'king6818: route range invalidation' "$TLB"; then
	cat > /tmp/tlb_new_fn.txt <<'TLBEOF'
static inline void __flush_tlb_range(struct vm_area_struct *vma,
				     unsigned long start, unsigned long end,
				     unsigned long stride, bool last_level,
				     int tlb_level)
{
	/*
	 * king6818: route range invalidation through flush_tlb_mm().
	 * On S5P6818 a TLBI by VA does not reliably invalidate the entries
	 * held by other CPU clusters, so mprotect()/munmap() left writable
	 * mappings behind and user space kept writing to read-only pages.
	 * flush_tlb_mm() already downgrades to a full flush on this SoC.
	 */
	(void)start;
	(void)end;
	(void)stride;
	(void)last_level;
	(void)tlb_level;
	flush_tlb_mm(vma->vm_mm);
}
TLBEOF
	awk 'NR == FNR { fn = fn $0 "\n"; next }
	     /^static inline void __flush_tlb_range\(/ { printf "%s", fn; skip = 1; next }
	     skip && /^}$/ { skip = 0; next }
	     skip { next }
	     { print }' /tmp/tlb_new_fn.txt "$TLB" > /tmp/tlb_h.new
	if [ "$(grep -c 'king6818: route range invalidation' /tmp/tlb_h.new)" != "1" ]; then
		echo "FATAL: tlbflush patch not applied" >&2
		exit 1
	fi
	if [ "$(grep -c '^static inline void __flush_tlb_range(' /tmp/tlb_h.new)" != "1" ]; then
		echo "FATAL: __flush_tlb_range duplication" >&2
		exit 1
	fi
	mv /tmp/tlb_h.new "$TLB"
fi
if grep -q 'MAX_TLBI_RANGE_PAGES' "$TLB"; then
	echo "NOTE: MAX_TLBI_RANGE_PAGES still referenced outside range fn (ok)" >&2
fi
echo '--- tlbflush 补丁核对 ---'
sed -n '/^static inline void __flush_tlb_range/,/^}$/p' "$TLB"

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
