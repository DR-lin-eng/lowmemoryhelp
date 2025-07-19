#!/bin/bash

# ====================================================================
# 快速内存清理脚本
# 用于临时释放内存，无需重启
# ====================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 显示清理前内存状态
echo "清理前内存状态:"
free -h
echo ""

# 1. 清理页面缓存、目录项和inode
print_status "清理系统缓存..."
sync
echo 1 > /proc/sys/vm/drop_caches  # 清理页面缓存
echo 2 > /proc/sys/vm/drop_caches  # 清理目录项和inode
echo 3 > /proc/sys/vm/drop_caches  # 清理所有缓存

# 2. 压缩内存（如果支持）
if [ -f /proc/sys/vm/compact_memory ]; then
    print_status "压缩内存碎片..."
    echo 1 > /proc/sys/vm/compact_memory
fi

# 3. 清理swap缓存（如果有swap）
if [ -f /proc/swaps ] && [ "$(cat /proc/swaps | wc -l)" -gt 1 ]; then
    print_status "优化swap使用..."
    # 临时禁用再启用swap以清理缓存
    swapoff -a
    swapon -a
fi

# 4. 清理临时文件
print_status "清理临时文件..."
find /tmp -type f -atime +1 -delete 2>/dev/null || true
find /var/tmp -type f -atime +1 -delete 2>/dev/null || true

# 5. 清理日志缓存
print_status "清理系统日志缓存..."
journalctl --vacuum-size=50M 2>/dev/null || true

# 6. 终止占用内存过多的进程（可选，谨慎使用）
if [ "$1" = "--kill-heavy" ]; then
    print_warning "终止占用内存超过10%的非系统进程..."
    ps aux --sort=-%mem | awk 'NR>1 && $4>10 && $11!~/^\[/ {print $2, $11, $4"%"}' | while read pid cmd mem; do
        echo "发现高内存进程: $cmd ($pid) - $mem"
        read -p "是否终止进程 $cmd? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            print_status "已终止进程: $cmd"
        fi
    done
fi

# 显示清理后内存状态
echo ""
echo "清理后内存状态:"
free -h
echo ""

# 计算释放的内存
before_free=$(cat /proc/meminfo | grep MemAvailable | awk '{print $2}')
print_status "内存清理完成！"
echo "使用 'free -h' 查看当前内存状态"
echo "使用 './quick-clean.sh --kill-heavy' 来终止高内存占用进程"