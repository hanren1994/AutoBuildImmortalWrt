#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

#echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
# 下载 run 文件仓库
echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

# 拷贝 run/arm64 下所有 run 文件和ipk文件 到 extra-packages 目录
mkdir -p /home/build/immortalwrt/extra-packages
cp -r /tmp/store-run-repo/run/arm64/* /home/build/immortalwrt/extra-packages/

echo "✅ Run files copied to extra-packages:"
ls -lh /home/build/immortalwrt/extra-packages/*.run
# 解压并拷贝ipk到packages目录
sh shell/prepare-packages.sh
ls -lah /home/build/immortalwrt/packages/
# 添加架构优先级信息
sed -i '1i\
arch aarch64_generic 10\n\
arch aarch64_cortex-a53 15' repositories.conf


# ========== RAX3000M 256M闪存DTS扩容补丁 20260630新增==========
if [ "$PROFILE" = "cmcc_rax3000m" ]; then
    DTS_FILE=/home/build/immortalwrt/target/linux/mediatek-filogic/dts/mt7981_cmcc_rax3000m.dts
    echo "🔧 检测到RAX3000M，自动修改DTS为256MB SPI Flash分区"
    # 闪存总容量 0x4000000(128M) → 0x8000000(256M)
    sed -i 's/reg = <0 0x4000000>/reg = <0 0x8000000>/' $DTS_FILE
    # firmware分区 0x3fb0000 → 0x7fb0000
    sed -i 's/reg = <0x50000 0x3fb0000>/reg = <0x50000 0x7fb0000>/' $DTS_FILE
fi

# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
#24.10.0
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/custom-packages.sh =======
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    # 这2款 暂时不支持第三方插件的集成 snapshot版本太高 opkg换成apk包管理器 6.12内核 
    echo "Model:$PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn luci-i18n-homeproxy-zh-cn"
else
    echo "Other Model:$PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" 20260630修改
# 构建固件，RAX3000M内置自动扩容，ROOTFS预留空白供自动拉伸
if [ "$PROFILE" = "cmcc_rax3000m" ]; then
    echo "🚀 RAX3000M 256M定制：内置首次开机自动扩容，ROOTFS_PARTSIZE=110M"
    # 创建开机自动扩容初始化脚本，打包进固件
    mkdir -p /home/build/immortalwrt/files/etc/init.d
    cat > /home/build/immortalwrt/files/etc/init.d/auto_expand_overlay << "SCRIPT_EOF"
#!/bin/sh /etc/rc.common
START=99
boot() {
    # 仅全新刷机第一次运行，标记文件避免重复扩容
    local mark="/root/.overlay_expanded_ok"
    if [ ! -f "$mark" ]; then
        echo "【自动扩容】检测空闲闪存，拉伸overlay至分区末尾"
        # 适配MT7981 squashfs+jffs2布局，自动占用firmware全部空闲空间
        root_part=$(awk '/rootfs_data/ {print $1}' /proc/mtd)
        if [ -n "$root_part" ]; then
            jffs2resize /dev/$root_part
            touch "$mark"
            echo "扩容完成，自动重启生效"
            reboot
        fi
    fi
}
SCRIPT_EOF
    # 添加执行权限
    chmod 755 /home/build/immortalwrt/files/etc/init.d/auto_expand_overlay
    # 设置开机自启
    echo "/etc/init.d/auto_expand_overlay enable" >> /home/build/immortalwrt/files/etc/rc.local
    # 编译固件，预留14M空闲闪存用于自动扩容
    make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=110
else
    make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
