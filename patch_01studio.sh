#!/bin/bash
# ==============================================================================
# 01Studio K230 Linux-Debian 1.4 官方资产与服务自动化注入补丁脚本
#
# 功能：
# 1. 替换 defconfig 为 01Studio 官方 1.4 全量稳定内核配置 (DRM/ST7701S/FT5306/D-Cache)
# 2. 替换设备树与开机 Logo (k230-canmv-01studio-lcd.dtb, hdmi.dtb, logo.yuv, fw_jump)
# 3. 将 U-Boot 烧录头替换为 fw_jump_add_uboot_head.bin 写入 SD 卡 Sector 1024 (512KB)
# 4. 注入驱动模块 (8189fs.ko, 8733bs.ko, vvcam_*.ko, nonai2d.ko) 并重建 depmod
# 5. 预置 WiFi 自动连接 (mxjtea2020_2.4G)
# 6. 预置 SSH root 登录 (密码 root)
# 7. 预置 VVCAM 摄像头服务与 isp_media_server
# 8. 预置 mount_boot.service 自动扩容根分区
# 9. 预置 XFCE4 桌面环境、KMS/DRM modesetting 与 X11VNC/XRDP 远程桌面
# ==============================================================================

set -e

# ==============================================================================
# 子流程：Rootfs 驱动、网络、SSH 与系统服务注入
# ==============================================================================
if [ "$1" == "--inject-rootfs" ]; then
    TARGET_DIR="$2"
    TARGET_BOARD="${3:-canmv}"
    TARGET_OS="${4:-debian13}"
    TARGET_TYPE="${5:-desktop}"
    ROOT_DIR="${6:-$(pwd)}"

    echo "======================================================================"
    echo ">>> [01Studio] Executing Rootfs Injection on: $TARGET_DIR"
    echo "======================================================================"

    if [ ! -d "$TARGET_DIR" ]; then
        echo "[-] Error: Target rootfs directory $TARGET_DIR does not exist!"
        exit 1
    fi

    # 查找资产目录
    ASSETS_DIR=""
    for d in "$ROOT_DIR/01studio_1.4_assets" "$ROOT_DIR/assets_source/01studio_1.4_assets" "/01studio_1.4_assets"; do
        if [ -d "$d" ]; then
            ASSETS_DIR="$d"
            break
        fi
    done

    # 1. 注入内核驱动模块到 /usr/lib/modules/6.6.36/updates/
    echo ">>> [Rootfs] Injecting 6.6.36 kernel modules..."
    MOD_DIR="${TARGET_DIR}/usr/lib/modules/6.6.36/updates"
    mkdir -p "${MOD_DIR}"
    if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR/modules_updates" ]; then
        find "$ASSETS_DIR/modules_updates" -name "*.ko" -exec cp -fv {} "${MOD_DIR}/" \;
        if [ -d "$ASSETS_DIR/modules_updates/v4l2" ]; then
            cp -rfv "$ASSETS_DIR/modules_updates/v4l2" "${MOD_DIR}/"
        fi
    fi

    # 建立 depmod 模块依赖关系索引
    if command -v depmod &>/dev/null; then
        depmod -a -b "${TARGET_DIR}" 6.6.36 2>/dev/null || true
    fi
    chroot "${TARGET_DIR}" depmod -a 6.6.36 2>/dev/null || true

    # 确保 /etc/modules 包含 8189fs 驱动模块
    mkdir -p "${TARGET_DIR}/etc"
    if [ -f "${TARGET_DIR}/etc/modules" ]; then
        grep -q "8189fs" "${TARGET_DIR}/etc/modules" || echo "8189fs" >> "${TARGET_DIR}/etc/modules"
    else
        echo "8189fs" > "${TARGET_DIR}/etc/modules"
    fi

    # 2. 开机自动连接指定 WiFi (mxjtea2020_2.4G)
    echo ">>> [Rootfs] Configuring WiFi auto-connect..."
    mkdir -p "${TARGET_DIR}/etc/wpa_supplicant"
    cat << 'EOF_WPA' > "${TARGET_DIR}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=CN

network={
    ssid="mxjtea2020_2.4G"
    psk="mxjtea2020"
    key_mgmt=WPA-PSK
    priority=1
}
EOF_WPA
    chmod 600 "${TARGET_DIR}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

    mkdir -p "${TARGET_DIR}/etc/systemd/network"
    cat << 'EOF_NET' > "${TARGET_DIR}/etc/systemd/network/20-wlan0.network"
[Match]
Name=wlan0

[Network]
DHCP=yes
EOF_NET

    mkdir -p "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/wpa_supplicant@.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"
    ln -sf /lib/systemd/system/systemd-networkd.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
    ln -sf /lib/systemd/system/systemd-resolved.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" 2>/dev/null || true

    # 3. 开启 root 密码登录与 SSH 服务
    echo ">>> [Rootfs] Configuring SSH root access (password: root)..."
    echo 'root:root' | chroot "${TARGET_DIR}" chpasswd 2>/dev/null || true
    mkdir -p "${TARGET_DIR}/etc/ssh/sshd_config.d"
    cat << 'EOF_SSH' > "${TARGET_DIR}/etc/ssh/sshd_config.d/01-permit-root.conf"
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF_SSH
    if [ -f "${TARGET_DIR}/etc/ssh/sshd_config" ]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${TARGET_DIR}/etc/ssh/sshd_config"
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "${TARGET_DIR}/etc/ssh/sshd_config"
    fi
    ln -sf /lib/systemd/system/ssh.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || true

    # 4. 预置 VVCAM 摄像头服务与 isp_media_server
    echo ">>> [Rootfs] Installing VVCAM & isp_media_server..."
    mkdir -p "${TARGET_DIR}/usr/bin" "${TARGET_DIR}/etc/vvcam"
    if [ -n "$ASSETS_DIR" ] && [ -f "$ASSETS_DIR/isp_media_server" ]; then
        cp -fv "$ASSETS_DIR/isp_media_server" "${TARGET_DIR}/usr/bin/isp_media_server"
        chmod 755 "${TARGET_DIR}/usr/bin/isp_media_server"
    fi
    if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR/vvcam" ]; then
        cp -rfv "$ASSETS_DIR/vvcam/"* "${TARGET_DIR}/etc/vvcam/"
        chmod +x "${TARGET_DIR}/etc/vvcam/isp_start.sh" 2>/dev/null || true
        chmod +x "${TARGET_DIR}/etc/vvcam/S41adb_mtp" 2>/dev/null || true
    fi

    cat << 'EOF_VVCAM' > "${TARGET_DIR}/etc/systemd/system/vvcam.service"
[Unit]
Description=01Studio K230 VVCAM and ISP Media Server Service
After=network.target local-fs.target
DefaultDependencies=no

[Service]
Type=forking
ExecStart=/etc/vvcam/isp_start.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_VVCAM
    ln -sf /etc/systemd/system/vvcam.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/vvcam.service"

    # 5. 预置 mount_boot.service 与首次开机自动扩容根分区
    echo ">>> [Rootfs] Installing mount_boot.service and auto-resize script..."
    mkdir -p "${TARGET_DIR}/usr/local/bin"
    cat << 'EOF_RESIZE' > "${TARGET_DIR}/usr/local/bin/mount_boot.sh"
#!/bin/bash
# 1. 自动挂载 boot 分区
if ! mountpoint -q /boot; then
    mount /boot 2>/dev/null || true
fi

# 2. 开机首次自动扩容根分区到 SD 卡全容量
if [ ! -f /etc/.rootfs_resized ]; then
    echo "01Studio: Checking rootfs expansion..."
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || mount | grep ' on / ' | awk '{print $1}')
    if [ -n "$ROOT_DEV" ]; then
        DISK=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//')
        PARTNUM=$(echo "$ROOT_DEV" | grep -o -E '[0-9]+$')
        if [ -b "$DISK" ] && [ -n "$PARTNUM" ]; then
            echo "01Studio: Resizing $DISK partition $PARTNUM to 100%..."
            parted -s "$DISK" resizepart "$PARTNUM" 100% 2>/dev/null || true
            resize2fs "$ROOT_DEV" 2>/dev/null || true
            touch /etc/.rootfs_resized
            echo "01Studio: Root partition expanded successfully."
        fi
    fi
fi
EOF_RESIZE
    chmod 755 "${TARGET_DIR}/usr/local/bin/mount_boot.sh"

    cat << 'EOF_MNTBOOT' > "${TARGET_DIR}/etc/systemd/system/mount_boot.service"
[Unit]
Description=01Studio Mount Boot and Auto-Resize Rootfs
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/mount_boot.sh

[Install]
WantedBy=basic.target
EOF_MNTBOOT
    mkdir -p "${TARGET_DIR}/etc/systemd/system/basic.target.wants"
    ln -sf /etc/systemd/system/mount_boot.service "${TARGET_DIR}/etc/systemd/system/basic.target.wants/mount_boot.service"

    # 6. KMS/DRM 显示驱动绑定 /dev/dri/card0
    echo ">>> [Rootfs] Configuring KMS/DRM modesetting for card0..."
    mkdir -p "${TARGET_DIR}/etc/X11/xorg.conf.d"
    cat << 'EOF_XORG' > "${TARGET_DIR}/etc/X11/xorg.conf.d/20-modesetting.conf"
Section "Device"
    Identifier  "K230-DRM"
    Driver      "modesetting"
    Option      "kmsdev" "/dev/dri/card0"
    Option      "ShadowFB" "true"
EndSection

Section "Screen"
    Identifier  "Screen0"
    Device      "K230-DRM"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "480x800" "1920x1080" "1280x720"
    EndSubSection
EndSection
EOF_XORG

    # 7. LightDM root 自动登录
    mkdir -p "${TARGET_DIR}/etc/lightdm/lightdm.conf.d"
    cat << 'EOF_LDM' > "${TARGET_DIR}/etc/lightdm/lightdm.conf.d/01-autologin.conf"
[Seat:*]
autologin-user=root
autologin-user-timeout=0
user-session=xfce
EOF_LDM

    # 8. X11VNC 远程桌面服务
    echo ">>> [Rootfs] Configuring x11vnc service..."
    cat << 'EOF_VNC' > "${TARGET_DIR}/etc/systemd/system/x11vnc.service"
[Unit]
Description=x11vnc Remote Desktop Service
After=lightdm.service display-manager.service
Wants=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -forever -display :0 -auth guess -shared -rfbport 5900 -nopw
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_VNC
    ln -sf /etc/systemd/system/x11vnc.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/x11vnc.service"

    # 启用 xrdp (若安装了 xrdp)
    if [ -f "${TARGET_DIR}/lib/systemd/system/xrdp.service" ]; then
        ln -sf /lib/systemd/system/xrdp.service "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/xrdp.service"
    fi

    echo ">>> [Rootfs] Rootfs injection finished successfully!"
    exit 0
fi

# ==============================================================================
# 主流程：修改构建流水线代码与源码注入
# ==============================================================================

ROOT_DIR="${1:-$(pwd)}"
TARGET_BOARD="${2:-canmv}"
TARGET_OS="${3:-debian13}"
TARGET_TYPE="${4:-desktop}"

echo "======================================================================"
echo ">>> [01Studio] Starting Automated Patching and Asset Injection"
echo ">>> Target Root : $ROOT_DIR"
echo ">>> Board       : $TARGET_BOARD"
echo ">>> OS Version  : $TARGET_OS"
echo ">>> System Type : $TARGET_TYPE"
echo "======================================================================"

cd "$ROOT_DIR"

# ------------------------------------------------------------------------------
# 1. 查找并准备 01Studio 资产目录
# ------------------------------------------------------------------------------
ASSETS_DIR=""
CONFIG_FILE=""

if [ -d "$ROOT_DIR/01studio_1.4_assets" ]; then
    ASSETS_DIR="$ROOT_DIR/01studio_1.4_assets"
elif [ -d "$ROOT_DIR/assets_source/01studio_1.4_assets" ]; then
    ASSETS_DIR="$ROOT_DIR/assets_source/01studio_1.4_assets"
elif [ -f "$ROOT_DIR/01studio_1.4_assets.tar.gz" ]; then
    echo ">>> Unpacking $ROOT_DIR/01studio_1.4_assets.tar.gz..."
    tar -zxf "$ROOT_DIR/01studio_1.4_assets.tar.gz" -C "$ROOT_DIR"
    ASSETS_DIR="$ROOT_DIR/01studio_1.4_assets"
elif [ -f "$ROOT_DIR/assets_source/01studio_1.4_assets.tar.gz" ]; then
    echo ">>> Unpacking $ROOT_DIR/assets_source/01studio_1.4_assets.tar.gz..."
    tar -zxf "$ROOT_DIR/assets_source/01studio_1.4_assets.tar.gz" -C "$ROOT_DIR"
    ASSETS_DIR="$ROOT_DIR/01studio_1.4_assets"
fi

if [ -f "$ROOT_DIR/kernel_01studio_1.4.config" ]; then
    CONFIG_FILE="$ROOT_DIR/kernel_01studio_1.4.config"
elif [ -f "$ROOT_DIR/assets_source/kernel_01studio_1.4.config" ]; then
    CONFIG_FILE="$ROOT_DIR/assets_source/kernel_01studio_1.4.config"
fi

if [ -z "$ASSETS_DIR" ] || [ ! -d "$ASSETS_DIR" ]; then
    echo "[-] Error: 01studio_1.4_assets directory not found!"
    exit 1
fi

echo "[+] Assets directory verified: $ASSETS_DIR"
echo "[+] Kernel config verified  : $CONFIG_FILE"

# ------------------------------------------------------------------------------
# 2. 升级工具链与修复 upstream walnutpi-build 编译缺陷
# ------------------------------------------------------------------------------
echo ">>> [1/6] Patching board configuration and toolchain..."

if [ -f "board/$TARGET_BOARD/board.conf" ]; then
    sed -i 's|TOOLCHAIN_DOWN_URL=.*|TOOLCHAIN_DOWN_URL="https://download.kendryte.com/k230/downloads/dl/gcc/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2-20250410.tar.gz"|g' "board/$TARGET_BOARD/board.conf"
    sed -i 's|TOOLCHAIN_FILE_NAME=.*|TOOLCHAIN_FILE_NAME="Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2"|g' "board/$TARGET_BOARD/board.conf"
fi

# 修复 upstream walnutpi-build 已知的脚本变量污染与语法缺陷
sed -i 's/readonly IMAGE_FLAG_NO_SCREEN_DISPLAY/IMAGE_FLAG_NO_SCREEN_DISPLAY/g' scripts/image/build.sh || true
sed -i 's/readonly PART1_SIZE/PART1_SIZE/g' scripts/image/build.sh || true
sed -i 's/\[ -n "\$ENTER_img_file" \]/\[ -f "\$ENTER_img_file" \]/g' scripts/image/__make_prepare.sh || true
sed -i 's/local VERSION_APT=.*/local VERSION_APT="1.0.0"/g' scripts/image/__make_image.sh || true
sed -i 's/overlays=spidev0_0 spidev0_1 csi2/overlays="spidev0_0 spidev0_1 csi2"/g' "board/$TARGET_BOARD/config.txt" || true

# 修复 toolchain basename 变量污染 bug
sed -i 's/TOOLCHAIN_FILE_NAME=\$(basename "\$TOOLCHAIN_DOWN_URL")/TOOLCHAIN_TAR=\$(basename "\$TOOLCHAIN_DOWN_URL")/g' scripts/boot/build.sh scripts/kernel/build.sh || true
sed -i 's/\${PATH_TOOLCHAIN}\/\${TOOLCHAIN_FILE_NAME} -C/\${PATH_TOOLCHAIN}\/\${TOOLCHAIN_TAR} -C/g' scripts/boot/build.sh scripts/kernel/build.sh || true

# 修复 rootfs debootstrap second-stage 时 qemu-riscv64-static 缺失导致的 Exec format error
sed -i 's|LC_ALL=C LANGUAGE=C LANG=C chroot \${tmp_dir} /debootstrap/debootstrap --second-stage|mkdir -p ${tmp_dir}/usr/bin && cp -fv /usr/bin/qemu-riscv64-static ${tmp_dir}/usr/bin/ 2>/dev/null || true; LC_ALL=C LANGUAGE=C LANG=C chroot ${tmp_dir} /debootstrap/debootstrap --second-stage|g' scripts/rootfs/__gen.sh || true
sed -i '/debootstrap --foreign/a \    mkdir -p ${tmp_dir}/usr/bin && cp -fv /usr/bin/qemu-riscv64-static ${tmp_dir}/usr/bin/ 2>/dev/null || true' scripts/rootfs/__gen.sh || true

# ------------------------------------------------------------------------------
# 3. 换芯环节 1：替换 defconfig 为 01Studio 官方 1.4 内核配置
# ------------------------------------------------------------------------------
echo ">>> [2/6] Replacing kernel defconfig with 01Studio 1.4 verified configuration..."
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    cp -fv "$CONFIG_FILE" "board/$TARGET_BOARD/defconfig"
fi

# 补丁 scripts/kernel/__compile.sh：编译时优先注入 board/$TARGET_BOARD/defconfig
if ! grep -q "01Studio Patch: Custom Defconfig" scripts/kernel/__compile.sh; then
    sed -i '/make \$LINUX_CONFIG CROSS_COMPILE=/i \
    # 01Studio Patch: Custom Defconfig\
    if [ -f "${ROOT_DIR}/board/'"$TARGET_BOARD"'/defconfig" ]; then\
        echo ">>> [01Studio] Applying 01Studio 1.4 defconfig to kernel source <<<"\
        cp -fv "${ROOT_DIR}/board/'"$TARGET_BOARD"'/defconfig" "${SOURCE_kernel}/arch/riscv/configs/${LINUX_CONFIG}"\
        cp -fv "${ROOT_DIR}/board/'"$TARGET_BOARD"'/defconfig" "${SOURCE_kernel}/.config"\
    fi' scripts/kernel/__compile.sh
fi

# ------------------------------------------------------------------------------
# 4. 换芯环节 2 前置：预置 01Studio 设备树、启动文件与 Logo 到 boot 目录
# ------------------------------------------------------------------------------
echo ">>> [3/6] Pre-populating board/$TARGET_BOARD/boot with 01Studio DTBs and firmware..."
mkdir -p "board/$TARGET_BOARD/boot"

cp -fv "$ASSETS_DIR/fw_jump_add_uboot_head.bin" "board/$TARGET_BOARD/boot/"
cp -fv "$ASSETS_DIR/k230-canmv-01studio-lcd.dtb" "board/$TARGET_BOARD/boot/"
cp -fv "$ASSETS_DIR/k230-canmv-01studio.dtb" "board/$TARGET_BOARD/boot/"
cp -fv "$ASSETS_DIR/hdmi_dtb" "board/$TARGET_BOARD/boot/"
cp -fv "$ASSETS_DIR/lcd_dtb" "board/$TARGET_BOARD/boot/"
cp -fv "$ASSETS_DIR/logo.yuv" "board/$TARGET_BOARD/boot/"

# ------------------------------------------------------------------------------
# 5. 换芯环节 4 前置：Debian 13 Desktop 软件清单注入 (XFCE4/LightDM/X11VNC/XRDP)
# ------------------------------------------------------------------------------
echo ">>> [4/6] Configuring Debian Desktop packages..."
DESKTOP_APT_FILE="board/$TARGET_BOARD/$TARGET_OS/apt-desktop"
if [ -f "$DESKTOP_APT_FILE" ]; then
    for pkg in xfce4 xfce4-terminal xorg lightdm fonts-wqy-zenhei x11vnc xrdp; do
        if ! grep -q "^$pkg" "$DESKTOP_APT_FILE"; then
            echo "$pkg" >> "$DESKTOP_APT_FILE"
        fi
    done
fi

# ------------------------------------------------------------------------------
# 6. 换芯环节 3 & 4：定义通用 Rootfs 驱动与服务注入函数
# ------------------------------------------------------------------------------
echo ">>> [5/6] Patching Rootfs and Image assembly hooks..."

# 注入 scripts/image/__make_prepare.sh，在 rootfs staging 准备完成后注入服务
if ! grep -q "01Studio Patch: Staging Rootfs Injection" scripts/image/__make_prepare.sh; then
    sed -i '/echo "prepare_staging completed./i \
    # 01Studio Patch: Staging Rootfs Injection\
    if [ -f "${ROOT_DIR}/patch_01studio.sh" ]; then\
        bash "${ROOT_DIR}/patch_01studio.sh" --inject-rootfs "${TMP_ROOTFS_DIR}" "'"$TARGET_BOARD"'" "'"$TARGET_OS"'" "'"$TARGET_TYPE"'" "${ROOT_DIR}"\
    fi' scripts/image/__make_prepare.sh
fi

# 注入 scripts/image/__make_image.sh：
# 1) 分区 1 挂载后，直接将 01Studio 引导文件写入 FAT32 boot 分区
# 2) U-Boot 烧录时，写入 Sector 1024 (512KB offset)
if ! grep -q "01Studio Patch: Direct Boot Partition Copy" scripts/image/__make_image.sh; then
    sed -i '/mount "\$MAPPER_DEVICE1" "\$TMP_mount_disk2\/boot"/a \
    # 01Studio Patch: Direct Boot Partition Copy\
    echo ">>> [01Studio] Synchronizing DTB, logo and uboot head into boot partition..."\
    cp -fv "'"$ASSETS_DIR"'/k230-canmv-01studio-lcd.dtb" "$TMP_mount_disk1/" || true\
    cp -fv "'"$ASSETS_DIR"'/k230-canmv-01studio.dtb" "$TMP_mount_disk1/" || true\
    cp -fv "'"$ASSETS_DIR"'/hdmi_dtb" "$TMP_mount_disk1/" || true\
    cp -fv "'"$ASSETS_DIR"'/lcd_dtb" "$TMP_mount_disk1/" || true\
    cp -fv "'"$ASSETS_DIR"'/logo.yuv" "$TMP_mount_disk1/" || true\
    cp -fv "'"$ASSETS_DIR"'/fw_jump_add_uboot_head.bin" "$TMP_mount_disk1/" || true' scripts/image/__make_image.sh
fi

if ! grep -q "01Studio Patch: Sector 1024 Header" scripts/image/__make_image.sh; then
    sed -i '/run_status "add \$BOOTLOADER_NAME/i \
    # 01Studio Patch: Sector 1024 Header (512KB Offset)\
    if [ -f "'"$ASSETS_DIR"'/fw_jump_add_uboot_head.bin" ]; then\
        echo ">>> [01Studio] Burning 01Studio fw_jump_add_uboot_head.bin to Sector 1024 (512KB offset)..."\
        dd if="'"$ASSETS_DIR"'/fw_jump_add_uboot_head.bin" of="$OUT_IMG_FILE" bs=512 seek=1024 conv=notrunc\
    fi' scripts/image/__make_image.sh
fi

echo "======================================================================"
echo "[+] [01Studio] All pipeline hooks successfully applied!"
echo "======================================================================"
