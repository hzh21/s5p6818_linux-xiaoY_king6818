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
#   实测基准：这块板子的 PHY 在 MDIO 地址 7。4.14 一直用 nanopi3 的 dtb
#   （那份 dtb 写的是 phy-addr = 7），所以 4.14 能上网；仓库里 king6818
#   的 dts 写 4，是错的。
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
python3 - "$D/s5p6818-king6818-common.dtsi" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
new = '''\t\tgmac0:ethernet@c0060000 {
\t\t\tpinctrl-names = "default";
\t\t\tpinctrl-0 = <&gmac_pins>;

\t\t\tstatus = "okay";
\t\t\t#address-cells = <0x1>;
\t\t\t#size-cells = <0x0>;

\t\t\tphy-mode = "rgmii";
\t\t\tphy-handle = <&ethernet_phy>;
\t\t\tsnps,phy-addr = <7>;

\t\t\tsnps,reset-gpio = <&gpio_e 22 0>;
\t\t\tsnps,reset-active-low;
\t\t\tsnps,reset-gpios = <&gpio_e 22 1>;
\t\t\tsnps,reset-delays-us = <0 10000 30000>;

\t\t\tmdio {
\t\t\t\tcompatible = "snps,dwmac-mdio";
\t\t\t\t#address-cells = <1>;
\t\t\t\t#size-cells = <0>;

\t\t\t\tethernet_phy: ethernet-phy@7 {
\t\t\t\t\treg = <7>;
\t\t\t\t};
\t\t\t};
\t\t};
'''
out, n = re.subn(r'\t\tgmac0:ethernet@c0060000 \{.*?\n\t\t\};\n', new, src, flags=re.S)
if n != 1:
    sys.exit('gmac0 node matched %d times, expected 1' % n)
open(p, 'w').write(out)
print('gmac0 rewritten: phy-mode=rgmii, phy-handle, phy addr = 7')
PY

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
echo '--- dts 补丁核对（gmac0 最终形态：应有 phy-handle / snps,dwmac-mdio，不应有 fixed-link）---'
sed -n '/gmac0:ethernet@c0060000/,/^\t\t};/p' "$D/s5p6818-king6818-common.dtsi"
echo '--- 关键点 ---'
grep -nE 'soc@0 \{|gmac0:|fixed-link|snps,dwmac-mdio|phy-handle|phy-addr|reset-gpios' \
	"$D/s5p6818-king6818-common.dtsi" | head
echo '--- 驱动接入核对 ---'
grep -n "DWMAC_NEXELL" "$S/Kconfig" "$S/Makefile"
wc -l "$S/dwmac-nexell.c"
grep -n 'nexell,s5p6818-gmac' "$S/dwmac-nexell.c"
