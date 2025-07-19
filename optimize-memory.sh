#!/bin/bash

# ====================================================================
# 低内存系统优化脚本
# 适用于内存小于2GB的Linux系统
# 支持Debian/Ubuntu系统
# ====================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印彩色输出
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

# 备份配置文件
backup_configs() {
    print_header "备份配置文件"
    
    local backup_dir="/root/memory_optimization_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份重要配置文件
    cp /etc/sysctl.conf "$backup_dir/sysctl.conf.bak" 2>/dev/null || true
    cp /etc/fstab "$backup_dir/fstab.bak" 2>/dev/null || true
    cp /etc/systemd/system.conf "$backup_dir/system.conf.bak" 2>/dev/null || true
    
    print_status "配置文件已备份到: $backup_dir"
}

# 显示当前内存状态
show_memory_status() {
    print_header "当前系统内存状态"
    
    echo "内存信息:"
    free -h
    echo ""
    
    echo "Swap信息:"
    cat /proc/swaps 2>/dev/null || echo "无swap设备"
    echo ""
    
    echo "占用内存最多的进程:"
    ps aux --sort=-%mem | head -6
    echo ""
}

# 配置内核参数
optimize_kernel_params() {
    print_header "优化内核参数"
    
    # 备份原始配置
    cp /etc/sysctl.conf /etc/sysctl.conf.backup_$(date +%Y%m%d) 2>/dev/null || true
    
    # 添加内存优化参数
    cat >> /etc/sysctl.conf << EOF

# ====== 内存优化参数 ======
# 更积极使用swap
vm.swappiness=90

# 内存超量分配
vm.overcommit_memory=1
vm.overcommit_ratio=50

# 脏页控制 - 更频繁写入磁盘
vm.dirty_ratio=10
vm.dirty_background_ratio=3

# 更积极回收缓存
vm.vfs_cache_pressure=200

# 最小空闲内存
vm.min_free_kbytes=32768

# 内存回收模式
vm.zone_reclaim_mode=1

# 减少内核日志缓冲区
kernel.printk=3 4 1 3

# 网络内存优化
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=65536
net.core.wmem_default=65536

EOF

    # 应用配置
    sysctl -p
    print_status "内核参数优化完成"
}

# 创建并优化swap
optimize_swap() {
    print_header "优化Swap配置"
    
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    local swap_size=$((total_mem * 2))  # swap大小为内存的2倍
    
    # 如果内存小于1GB，至少创建2GB swap
    if [ $swap_size -lt 2048 ]; then
        swap_size=2048
    fi
    
    print_status "检测到系统内存: ${total_mem}MB"
    print_status "将创建 ${swap_size}MB 的swap文件"
    
    # 检查现有swap文件
    if [ -f /swapfile ]; then
        print_warning "发现现有swap文件，将重新配置"
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
    
    # 创建新的swap文件
    fallocate -l ${swap_size}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # 添加到fstab
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    print_status "Swap文件创建完成: ${swap_size}MB"
}

# 配置zram压缩内存
setup_zram() {
    print_header "配置ZRAM压缩内存"
    
    # 检查zram模块
    if ! lsmod | grep -q zram; then
        modprobe zram 2>/dev/null || {
            print_warning "无法加载zram模块，跳过zram配置"
            return
        }
    fi
    
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local zram_size=$((mem_total / 4))  # zram大小为内存的1/4
    
    # 最少256MB
    if [ $zram_size -lt 256 ]; then
        zram_size=256
    fi
    
    print_status "创建 ${zram_size}MB 的zram设备"
    
    # 创建zram设备
    echo "${zram_size}M" > /sys/block/zram0/disksize 2>/dev/null || {
        print_warning "无法创建zram设备"
        return
    }
    
    mkswap /dev/zram0
    swapon -p 10 /dev/zram0  # 高优先级
    
    # 创建zram服务
    cat > /etc/systemd/system/zram.service << EOF
[Unit]
Description=Enable zram compressed swap
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/bash -c 'modprobe zram && echo ${zram_size}M > /sys/block/zram0/disksize && mkswap /dev/zram0 && swapon -p 10 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null || true; echo 1 > /sys/block/zram0/reset 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable zram.service
    
    print_status "ZRAM配置完成"
}

# 优化tmpfs
optimize_tmpfs() {
    print_header "优化临时文件系统"
    
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local tmp_size=$((mem_total / 8))  # /tmp使用1/8内存
    local log_size=$((mem_total / 16)) # /var/log使用1/16内存
    
    # 最小值设置
    [ $tmp_size -lt 128 ] && tmp_size=128
    [ $log_size -lt 64 ] && log_size=64
    
    # 备份fstab
    cp /etc/fstab /etc/fstab.backup_$(date +%Y%m%d)
    
    # 添加tmpfs挂载
    if ! grep -q "tmpfs /tmp" /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=${tmp_size}M 0 0" >> /etc/fstab
    fi
    
    if ! grep -q "tmpfs /var/log" /etc/fstab; then
        echo "tmpfs /var/log tmpfs defaults,noatime,mode=0755,size=${log_size}M 0 0" >> /etc/fstab
    fi
    
    print_status "Tmpfs配置完成 - /tmp: ${tmp_size}MB, /var/log: ${log_size}MB"
}

# 清理系统缓存
clean_system_cache() {
    print_header "清理系统缓存"
    
    # 清理包缓存
    apt-get clean 2>/dev/null || yum clean all 2>/dev/null || true
    
    # 清理日志文件
    journalctl --vacuum-time=3d 2>/dev/null || true
    find /var/log -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    
    # 清理临时文件
    find /tmp -type f -mtime +1 -delete 2>/dev/null || true
    find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
    
    # 清理内存缓存
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    print_status "系统缓存清理完成"
}

# 禁用不必要的服务
optimize_services() {
    print_header "优化系统服务"
    
    # 常见的可以禁用的服务（根据需要调整）
    local services_to_disable=(
        "bluetooth"
        "cups"
        "avahi-daemon"
        "ModemManager"
        "wpa_supplicant"
    )
    
    for service in "${services_to_disable[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable "$service" 2>/dev/null || true
            systemctl stop "$service" 2>/dev/null || true
            print_status "已禁用服务: $service"
        fi
    done
    
    print_status "服务优化完成"
}

# 创建内存监控脚本
create_memory_monitor() {
    print_header "创建内存监控脚本"
    
    cat > /usr/local/bin/memory-monitor << 'EOF'
#!/bin/bash

# 内存监控脚本
while true; do
    # 获取内存使用率
    mem_usage=$(free | grep Mem | awk '{printf("%.1f"), $3/$2 * 100.0}')
    swap_usage=$(free | grep Swap | awk '{if($2>0) printf("%.1f"), $3/$2 * 100.0; else print "0.0"}')
    
    # 获取当前时间
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 如果内存使用率超过85%，清理缓存
    if (( $(echo "$mem_usage > 85" | bc -l) )); then
        echo "[$timestamp] 内存使用率过高: ${mem_usage}%, 清理缓存"
        sync
        echo 1 > /proc/sys/vm/drop_caches
    fi
    
    # 记录状态
    echo "[$timestamp] 内存: ${mem_usage}%, Swap: ${swap_usage}%"
    
    sleep 300  # 5分钟检查一次
done
EOF

    chmod +x /usr/local/bin/memory-monitor
    
    # 创建systemd服务
    cat > /etc/systemd/system/memory-monitor.service << EOF
[Unit]
Description=Memory Monitor Service
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/memory-monitor
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable memory-monitor.service
    systemctl start memory-monitor.service
    
    print_status "内存监控服务已创建并启动"
}

# 创建内存清理别名
create_memory_aliases() {
    print_header "创建内存管理别名"
    
    cat >> /root/.bashrc << 'EOF'

# ====== 内存管理别名 ======
alias meminfo='free -h && echo "" && cat /proc/swaps'
alias memclean='sync && echo 3 > /proc/sys/vm/drop_caches && echo "缓存已清理"'
alias memtop='ps aux --sort=-%mem | head -10'
alias swapinfo='cat /proc/swaps && echo "" && swapon -s'
alias zraminfo='cat /sys/block/zram*/mm_stat 2>/dev/null || echo "zram未配置"'

EOF

    print_status "内存管理别名已添加到 /root/.bashrc"
}

# 主函数
main() {
    print_header "低内存系统优化脚本启动"
    
    check_root
    
    echo "此脚本将对您的系统进行以下优化："
    echo "1. 备份配置文件"
    echo "2. 优化内核参数"
    echo "3. 配置Swap"
    echo "4. 设置ZRAM压缩内存"
    echo "5. 优化tmpfs"
    echo "6. 清理系统缓存"
    echo "7. 禁用不必要服务"
    echo "8. 创建内存监控"
    echo ""
    
    read -p "是否继续? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        exit 0
    fi
    
    # 显示优化前状态
    show_memory_status
    
    # 执行优化步骤
    backup_configs
    optimize_kernel_params
    optimize_swap
    setup_zram
    optimize_tmpfs
    clean_system_cache
    optimize_services
    create_memory_monitor
    create_memory_aliases
    
    print_header "优化完成"
    
    echo "系统优化完成！建议重启系统以确保所有配置生效。"
    echo ""
    echo "新增的命令别名："
    echo "  meminfo  - 查看内存信息"
    echo "  memclean - 清理内存缓存"
    echo "  memtop   - 显示占用内存最多的进程"
    echo "  swapinfo - 查看swap信息"
    echo "  zraminfo - 查看zram信息"
    echo ""
    echo "配置文件备份位置: /root/memory_optimization_backup_*"
    echo ""
    
    read -p "是否现在重启系统? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# 运行主函数
main "$@"