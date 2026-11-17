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

# 补丁 3：板子的 RGMII 是 fixed-link（4.14 上 mdio 的 addr4 从未绑定驱动，
#          实际走的是 fixed-0 总线）。4.14 把 fixed-link 写在 ethernet-phy@4
#          里面，而 5.10 的 of_phy_is_fixed_link() 只认 MAC 节点下的
#          fixed-link，所以在 gmac0 里补一份
awk '{print}
     /snps,reset-delays-us/ && !done {
	print "\t\t\tfixed-link {"
	print "\t\t\t\tspeed = <1000>;"
	print "\t\t\t\tfull-duplex;"
	print "\t\t\t};"
	done=1
     }' "$D/s5p6818-king6818-common.dtsi" > /tmp/dts.new
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

echo '--- dtb Makefile ---'
cat "$D/Makefile"
echo '--- dts 补丁核对 ---'
grep -nE 'soc@0 \{|pinctrl\.dtsi|fixed-link|speed = <1000>|full-duplex' \
	"$D/s5p6818-king6818-common.dtsi" | head
echo '--- 驱动接入核对 ---'
grep -n "DWMAC_NEXELL" "$S/Kconfig" "$S/Makefile"
wc -l "$S/dwmac-nexell.c"
grep -n 'nexell,s5p6818-gmac' "$S/dwmac-nexell.c"
