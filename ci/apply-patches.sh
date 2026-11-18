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

# 补丁 3：绝不能给 gmac0 节点加 fixed-link。
#          5.10 的 of_phy_is_fixed_link(MAC 节点) 一旦为真，phylink 就进入
#          MLO_AN_FIXED，完全不再 attach PHY。RGMII 的 RX 时钟由 PHY 提供，
#          PHY 不被初始化 -> RX DMA 一个包都收不到（实测 RX=0，TX 记账正常）。
#          4.14 跑的是 nanopi3 的 dtb，没有这个属性，走的是真实 PHY 路径。
#          所以这里反过来：删掉 mdio 子节点，让 phy_addr 保持 -1，
#          stmmac_mdio_register() 会扫描 0..31 自动发现 PHY。
awk '/^\t\t\tmdio \{$/ { skip = 1; next }
     skip && /^\t\t\t\};$/ { skip = 0; next }
     !skip { print }' \
	"$D/s5p6818-king6818-common.dtsi" > /tmp/dts.new
mv /tmp/dts.new "$D/s5p6818-king6818-common.dtsi"

# 补丁 3b：5.10 只认 snps,reset-gpios（复数），极性看 gpio flag，
#          不再读 snps,reset-active-low。复位脚 gpio_e22 低有效 -> flag=1
sed -i 's|snps,reset-gpio = <&gpio_e 22 0>;|snps,reset-gpios = <\&gpio_e 22 1>;|' \
	"$D/s5p6818-king6818-common.dtsi"

# 补丁 3c：删掉 snps,phy-addr，让 plat->phy_addr = -1，
#          stmmac_mdio_register() 扫全总线后自动回填找到的地址
sed -i '/snps,phy-addr/d' "$D/s5p6818-king6818-common.dtsi"

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
echo '--- dts 补丁核对（gmac0 最终形态，不应出现 fixed-link / mdio / phy-addr）---'
sed -n '/gmac0:ethernet@c0060000/,/^\t\t};/p' "$D/s5p6818-king6818-common.dtsi"
echo '--- 关键点 ---'
grep -nE 'soc@0 \{|gmac0:|fixed-link|mdio \{|phy-addr|reset-gpios' \
	"$D/s5p6818-king6818-common.dtsi" | head
echo '--- 驱动接入核对 ---'
grep -n "DWMAC_NEXELL" "$S/Kconfig" "$S/Makefile"
wc -l "$S/dwmac-nexell.c"
grep -n 'nexell,s5p6818-gmac' "$S/dwmac-nexell.c"
