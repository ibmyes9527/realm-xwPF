# ---- 服务管理抽象层 ----
svc_start()        { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm start;   else systemctl start realm;   fi; }
svc_stop()         { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm stop;    else systemctl stop realm;    fi; }
svc_restart()      { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm restart; else systemctl restart realm; fi; }
svc_enable()       { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update add realm default >/dev/null 2>&1; else systemctl enable realm >/dev/null 2>&1;  fi; }
svc_disable()      { if [ "$INIT_SYSTEM" = "openrc" ]; then rc-update del realm default >/dev/null 2>&1; else systemctl disable realm >/dev/null 2>&1; fi; }
svc_daemon_reload() { [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload; }
svc_is_active() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm status >/dev/null 2>&1; return $?
    else local s=$(systemctl is-active realm 2>/dev/null); [ "$s" = "active" ]; fi
}
svc_status_text() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-service realm status >/dev/null 2>&1; then echo "active"; else echo "inactive"; fi
    else systemctl is-active realm 2>/dev/null; fi
}
svc_enabled_text() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if rc-update show default 2>/dev/null | grep -q realm; then echo "enabled"; else echo "disabled"; fi
    else systemctl is-enabled realm 2>/dev/null; fi
}
svc_status_detail() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then rc-service realm status
    else systemctl status realm --no-pager -l; fi
}
svc_logs() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        echo -e "${YELLOW}OpenRC 环境，使用系统日志:${NC}"
        tail -f /var/log/messages 2>/dev/null || echo -e "${RED}日志文件不可用${NC}"
    else journalctl -u realm -f --no-pager; fi
}

# 检测虚拟化环境
detect_virtualization() {
    local virt_type="物理机"

    # 检测各种虚拟化技术
    if [ -f /proc/vz/version ]; then
        virt_type="OpenVZ"
    elif [ -d /proc/vz ]; then
        virt_type="OpenVZ容器"
    elif grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        virt_type="LXC容器"
    elif [ -f /.dockerenv ]; then
        virt_type="Docker容器"
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local detected=$(systemd-detect-virt 2>/dev/null)
        case "$detected" in
            "kvm") virt_type="KVM虚拟机" ;;
            "qemu") virt_type="QEMU虚拟机" ;;
            "vmware") virt_type="VMware虚拟机" ;;
            "xen") virt_type="Xen虚拟机" ;;
            "lxc") virt_type="LXC容器" ;;
            "docker") virt_type="Docker容器" ;;
            "openvz") virt_type="OpenVZ容器" ;;
            "none") virt_type="物理机" ;;
            *) virt_type="未知虚拟化($detected)" ;;
        esac
    elif [ -e /proc/user_beancounters ]; then
        virt_type="OpenVZ容器"
    elif dmesg 2>/dev/null | grep -i "hypervisor detected" >/dev/null; then
        virt_type="虚拟机"
    fi

    echo "$virt_type"
}

# 统一下载函数
download_from_sources() {
    local url="$1"
    local target_path="$2"

    if curl -fsSL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$url" -o "$target_path"; then
        echo -e "${GREEN}✓ 下载成功${NC}" >&2
        return 0
    else
        echo -e "${RED}✗ 下载失败${NC}" >&2
        return 1
    fi
}

# 获取realm最新版本号
get_latest_realm_version() {
    echo -e "${YELLOW}获取最新版本信息...${NC}" >&2

    local latest_version=$(curl -sL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "https://gh.henhei.win/https://github.com/zhboner/realm/releases" 2>/dev/null | \
        head -2100 | \
        sed -n 's|.*releases/tag/v\([0-9.]*\).*|v\1|p' | head -1)

    if [ -z "$latest_version" ]; then
        echo -e "${YELLOW}使用当前最新版本 ${REALM_VERSION}${NC}" >&2
        latest_version="$REALM_VERSION"
    fi

    echo -e "${GREEN}✓ 检测到最新版本: ${latest_version}${NC}" >&2
    echo "$latest_version"
}

# 智能重启realm服务
restart_realm_service() {
    local was_running="$1"
    local is_update="${2:-false}"  # 是否为更新场景

    if [ "$was_running" = true ] || [ "$is_update" = true ]; then
        echo -e "${YELLOW}正在启动realm服务...${NC}"
        if svc_start >/dev/null 2>&1; then
            echo -e "${GREEN}✓ realm服务已启动${NC}"
        else
            echo -e "${YELLOW}服务启动失败，尝试重新初始化...${NC}"
            start_empty_service
        fi
    else
        # 首次安装，启动空服务完成安装
        start_empty_service
    fi
}

# 比较realm版本并询问更新
compare_and_ask_update() {
    local current_version="$1"
    local latest_version="$2"

    # 提取当前版本号进行比较
    local current_ver=$(echo "$current_version" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$current_ver" ]; then
        current_ver="v0.0.0"
    fi

    # 统一版本格式（添加v前缀）
    if [[ ! "$current_ver" =~ ^v ]]; then
        current_ver="v$current_ver"
    fi
    if [[ ! "$latest_version" =~ ^v ]]; then
        latest_version="v$latest_version"
    fi

    # 比较版本
    if [ "$current_ver" = "$latest_version" ]; then
        echo -e "${GREEN}✓ 当前版本已是最新版本${NC}"
        return 1
    else
        echo -e "${YELLOW}发现新版本: ${current_ver} → ${latest_version}${NC}"
        read -p "是否更新到最新版本？(y/n) [默认: n]: " update_choice
        if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}使用现有的 realm 安装${NC}"
            return 1
        fi
        echo -e "${YELLOW}将更新到最新版本...${NC}"
        return 0
    fi
}

# 安全停止realm服务
safe_stop_realm_service() {
    local service_was_running=false

    if svc_is_active; then
        echo -e "${BLUE}检测到realm服务正在运行，正在停止服务...${NC}"
        if svc_stop >/dev/null 2>&1; then
            echo -e "${GREEN}✓ realm服务已停止${NC}"
            service_was_running=true
        else
            echo -e "${RED}✗ 停止realm服务失败，无法安全更新${NC}"
            return 1
        fi
    fi

    echo "$service_was_running"
}

# 安装 realm - 虚拟化适配 (已暴力魔改版)
install_realm() {
    echo -e "${GREEN}正在检查 realm 安装状态...${NC}"

    # 检测虚拟化环境并显示
    local virt_env=$(detect_virtualization)
    echo -e "${BLUE}检测到虚拟化环境: ${GREEN}${virt_env}${NC}"

    # 检查是否已安装realm
    if [ -f "${REALM_PATH}" ] && [ -x "${REALM_PATH}" ]; then
        if ! ${REALM_PATH} --help >/dev/null 2>&1; then
            echo -e "${YELLOW}检测到 realm 文件存在但可能已损坏，将重新安装...${NC}"
        else
            local current_version=""
            local version_output=""
            if version_output=$(${REALM_PATH} --version 2>&1); then
                current_version="$version_output"
            elif version_output=$(${REALM_PATH} -v 2>&1); then
                current_version="$version_output"
            else
                current_version="realm (版本检查失败，可能架构不匹配)"
                echo -e "${YELLOW}警告: 版本检查失败，错误信息: ${version_output}${NC}"
            fi

            echo -e "${GREEN}✓ 检测到已安装的 realm: ${current_version}${NC}"
            echo ""
            LATEST_VERSION=$(get_latest_realm_version)
            if ! compare_and_ask_update "$current_version" "$LATEST_VERSION"; then
                return 0
            fi
        fi
    else
        echo -e "${YELLOW}未检测到 realm 安装，开启本地物理强载模式...${NC}"
    fi

    # ========== 核心暴力魔改区：直接从 /root 抓取文件 ==========
    local download_file=""
    
    # 智能寻找 /root 目录下的 realm 压缩包
    local_package_path=$(ls /root/realm*.tar.gz 2>/dev/null | head -n 1)

    if [ -n "$local_package_path" ] && [ -f "$local_package_path" ]; then
        echo -e "${GREEN}✓ 霸王硬上弓成功！自动捕获本地文件: $local_package_path${NC}"
        download_file="$local_package_path"
    else
        echo -e "${RED}✗ 致命错误：在 /root 目录下没有找到 realm*.tar.gz！${NC}"
        echo -e "${YELLOW}请先用电脑下载好压缩包，拖拽上传到服务器的 /root 目录后再运行本脚本！${NC}"
        exit 1
    fi
    # =========================================================

    # 解压安装
    echo -e "${YELLOW}正在解压并执行物理植入...${NC}"

    local service_was_running=$(safe_stop_realm_service)
    if [ $? -ne 0 ]; then
        return 1
    fi

    local work_dir=$(dirname "$download_file")
    local archive_name=$(basename "$download_file")

    if (cd "$work_dir"
