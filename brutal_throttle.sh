#!/usr/bin/env bash
# extreme_tune.sh
# 极限调控神器 - ThinkPad T15 / Proxmox等通用方案
# 功能：
# 1. 初始化（安装依赖，禁用温控服务及热模块）
# 2. CPU 极限模式（锁最高频）
# 3. CPU 保守节能模式（1300MHz）
# 4.1 彻底关闭独立显卡（禁用 PCI + ACPI 断电）
# 4.2 重新打开独立显卡
# 5. 恢复默认设置（启用服务，恢复 CPU/GPU 设置）

set -euo pipefail
shopt -s nullglob

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo_color() {
  local color=$1; shift
  echo -e "${color}$*${RESET}"
}

REQUIRE_CONFIRM() {
  echo_color "$RED" "!!! 非常重要 !!!"
  echo_color "$YELLOW" "你将执行高风险操作，可能导致硬件损伤、系统不稳定。"
  read -rp "$(echo_color $RED "如果你非常确定要继续，请输入大写 YES : ")" CONF
  if [[ "$CONF" != "YES" ]]; then
    echo_color $CYAN "放弃操作。"
    exit 1
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo_color $RED "请以 root 身份运行： sudo $0"
    exit 1
  fi
}

install_deps() {
  echo_color $BLUE "[*] 安装必要依赖（cpufrequtils, pciutils 等）..."
  apt update || true
  apt install -y cpufrequtils pciutils || true
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo_color $GREEN "[*] 已检测到 NVIDIA 驱动及工具 nvidia-smi。"
  else
    echo_color $YELLOW "[!] 未检测到 nvidia-smi，GPU 相关操作会跳过。"
  fi
}

stop_disable_services() {
  echo_color $BLUE "[*] 停止并禁用热管理服务（thermald, power-profiles-daemon, tlp）..."
  for svc in thermald power-profiles-daemon tlp; do
    if systemctl list-unit-files | grep -q "$svc"; then
      systemctl stop "$svc" || true
      systemctl disable "$svc" || true
      echo_color $GREEN "  - 服务 $svc 已停止并禁用"
    fi
  done
}

blacklist_thermal_modules() {
  echo_color $BLUE "[*] 卸载并黑名单热控相关内核模块（intel_rapl intel_powerclamp powerclamp thermal）..."
  for mod in intel_rapl intel_powerclamp intel_pmc_core powerclamp thermal; do
    if lsmod | grep -q "^$mod"; then
      modprobe -r "$mod" || true
      echo_color $GREEN "  - 卸载模块 $mod"
    fi
  done

  local BLFILE=/etc/modprobe.d/99-extreme-thermal-blacklist.conf
  {
    echo "blacklist intel_rapl"
    echo "blacklist intel_powerclamp"
    echo "blacklist powerclamp"
    echo "blacklist thermal"
  } > "$BLFILE"
  echo_color $YELLOW "[*] 写入黑名单文件：$BLFILE"
  echo_color $YELLOW "[*] 注意：可能需要执行 'update-initramfs -u' 并重启才能生效。"
}

lock_cpu_freq() {
  local target="$1"
  echo_color $BLUE "[*] 尝试锁定 CPU 频率为 $target ..."
  local target_khz
  if [[ "$target" =~ ^[0-9]+(\.[0-9]+)?MHz$ ]]; then
    local m=${target%MHz}
    local k=$(( ${m/.*} * 1000 ))
    target_khz="${k}000"
  elif [[ "$target" =~ ^[0-9]+$ ]]; then
    target_khz="${target}000"
  else
    target_khz="$target"
  fi

  if command -v cpufreq-set >/dev/null 2>&1; then
    echo_color $GREEN "[*] 使用 cpufreq-set 设置频率..."
    cpufreq-set -r -g performance || true
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      if [[ -f "$c/cpufreq/scaling_setspeed" ]]; then
        echo "$target_khz" > "$c/cpufreq/scaling_setspeed" || true
      else
        echo_color $YELLOW "[!] $c 不支持 scaling_setspeed，尝试写 min/max..."
        echo "$target_khz" > "$c/cpufreq/scaling_min_freq" || true
        echo "$target_khz" > "$c/cpufreq/scaling_max_freq" || true
      fi
    done
  else
    echo_color $YELLOW "[!] 未检测到 cpufreq-set，尝试直接写 sysfs..."
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      if [[ -d "$c/cpufreq" ]]; then
        echo "$target_khz" > "$c/cpufreq/scaling_min_freq" || true
        echo "$target_khz" > "$c/cpufreq/scaling_max_freq" || true
      fi
    done
  fi

  echo_color $GREEN "[*] CPU 频率已尝试锁定。查看实际频率：cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
}

restore_defaults() {
  echo_color $BLUE "[*] 恢复默认设置：启用服务，移除黑名单，重载内核模块，恢复 CPU 和 GPU 默认调度..."
  for svc in thermald power-profiles-daemon tlp; do
    if systemctl list-unit-files | grep -q "$svc"; then
      systemctl enable "$svc" || true
      systemctl start "$svc" || true
      echo_color $GREEN "  - 服务 $svc 已启用并启动"
    fi
  done

  local BLFILE=/etc/modprobe.d/99-extreme-thermal-blacklist.conf
  if [[ -f "$BLFILE" ]]; then
    rm -f "$BLFILE"
    echo_color $YELLOW "[*] 移除黑名单文件：$BLFILE"
    update-initramfs -u || true
  fi

  for mod in intel_rapl intel_powerclamp powerclamp thermal; do
    modprobe "$mod" || true
  done

  # 还原 CPU 调频为 ondemand
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    if [[ -d "$c/cpufreq" ]]; then
      echo "ondemand" > "$c/cpufreq/scaling_governor" || true
      echo 0 > "$c/cpufreq/scaling_min_freq" 2>/dev/null || true
      echo 0 > "$c/cpufreq/scaling_max_freq" 2>/dev/null || true
    fi
  done

  # GPU 还原：打开显卡 ACPI 电源（如果有）
  echo_color $BLUE "[*] 还原独显电源（ACPI on）..."
  for gpu_dev in "${GPU_SELECTED_PATHS[@]:-}"; do
    echo "on" > "$gpu_dev/power/control" 2>/dev/null || true
  done

  echo_color $GREEN "[*] 恢复完成，建议重启确保所有设置生效。"
}

select_gpu_devices() {
  echo_color $CYAN "扫描 PCI 总线上的显卡设备..."
  mapfile -t gpu_devs < <(lspci -Dn | grep -Ei 'vga|3d' | awk '{print $1}')
  if [[ ${#gpu_devs[@]} -eq 0 ]]; then
    echo_color $RED "[!] 未检测到任何显卡设备。"
    return 1
  fi

  echo_color $CYAN "检测到以下显卡设备："
  for i in "${!gpu_devs[@]}"; do
    dev="${gpu_devs[i]}"
    desc=$(lspci -s "$dev" | cut -d' ' -f2-)
    echo_color $MAGENTA "  $((i+1))) $dev - $desc"
  done

  echo_color $YELLOW "请输入要操作的设备编号，多个用逗号分隔（例如 1,3），留空选择全部："
  read -r input
  if [[ -z "$input" ]]; then
    selected_paths=()
    for dev in "${gpu_devs[@]}"; do
      selected_paths+=("/sys/bus/pci/devices/0000:${dev}")
    done
  else
    IFS=',' read -ra sel_indices <<< "$input"
    selected_paths=()
    for idx in "${sel_indices[@]}"; do
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#gpu_devs[@]} )); then
        dev="${gpu_devs[$((idx-1))]}"
        path="/sys/bus/pci/devices/0000:${dev}"
        if [[ -d "$path" ]]; then
          selected_paths+=("$path")
        else
          echo_color $RED "[!] 设备路径不存在：$path"
        fi
      else
        echo_color $RED "[!] 无效编号：$idx"
      fi
    done
  fi

  if [[ ${#selected_paths[@]} -eq 0 ]]; then
    echo_color $RED "[!] 没有有效设备被选择。"
    return 1
  fi

  GPU_SELECTED_PATHS=("${selected_paths[@]}")
  echo_color $GREEN "[*] 已选定设备路径："
  for p in "${GPU_SELECTED_PATHS[@]}"; do
    echo "  - $p"
  done
  return 0
}

disable_gpu() {
  select_gpu_devices || { echo_color $RED "没有显卡设备可操作，返回主菜单"; return; }
  REQUIRE_CONFIRM
  echo_color $BLUE "[*] 关闭独立显卡（禁用 PCI 设备 + 断电）..."
  for gpu_dev in "${GPU_SELECTED_PATHS[@]}"; do
    echo_color $YELLOW "-> 禁用设备 $gpu_dev"
    echo 1 > "$gpu_dev/remove" 2>/dev/null || echo_color $RED "  禁用失败"
    echo "auto" > "$gpu_dev/power/control" 2>/dev/null || true
    echo 0 > "$gpu_dev/power/runtime_status" 2>/dev/null || true
    echo 0 > "$gpu_dev/power/runtime_autosuspend" 2>/dev/null || true
    echo_color $GREEN "  设备已断电"
  done
  echo_color $GREEN "[*] 独显已关闭。"
}

enable_gpu() {
  select_gpu_devices || { echo_color $RED "没有显卡设备可操作，返回主菜单"; return; }
  REQUIRE_CONFIRM
  echo_color $BLUE "[*] 重新启用独立显卡（重新扫描 PCI 总线设备）..."
  for gpu_dev in "${GPU_SELECTED_PATHS[@]}"; do
    # 从路径提取 PCI ID
    pci_id=$(basename "$gpu_dev")
    echo_color $YELLOW "-> 重新扫描设备 0000:$pci_id"
    echo 1 > /sys/bus/pci/rescan  # 通知重新扫描总线
    echo "on" > "$gpu_dev/power/control" 2>/dev/null || true
    echo_color $GREEN "  设备已重新启用"
  done
  echo_color $GREEN "[*] 独显已重新开启。"
}

menu() {
  cat <<EOF
${MAGENTA}===== 极限调控神器菜单 =====${RESET}
1) 初始化（安装依赖、禁用温控服务、黑名单热模块）
2) CPU 极限模式（锁最高频）
3) CPU 保守节能模式（1300MHz）
4) 彻底关闭独立显卡（禁用 PCI + 断电）
5) 重新开启独立显卡（扫描 PCI + 上电）
6) 恢复默认设置（启用服务，恢复 CPU/GPU）
0) 退出
============================
EOF
  read -rp "选择 (0-6): " choice
  case "$choice" in
    1)
      REQUIRE_CONFIRM
      install_deps
      stop_disable_services
      blacklist_thermal_modules
      echo_color $GREEN "[*] 初始化完成。"
      ;;
    2)
      REQUIRE_CONFIRM
      echo_color $YELLOW "[*] 启动 CPU 极限模式..."
      stop_disable_services
      blacklist_thermal_modules
      if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        MAXKHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        MAXMHZ=$((MAXKHZ/1000))
        lock_cpu_freq "${MAXMHZ}MHz"
      else
        echo_color $RED "[!] 无法读取 CPU 最大频率，尝试设置 performance 模式..."
        for c in /sys/devices/system/cpu/cpu[0-9]*; do
          if [[ -d "$c/cpufreq" ]]; then
            echo performance > "$c/cpufreq/scaling_governor" || true
          fi
        done
      fi
      echo_color $GREEN "[*] CPU 极限模式已启用。"
      ;;
    3)
      REQUIRE_CONFIRM
      echo_color $YELLOW "[*] 启动 CPU 保守节能模式（1300MHz）..."
      stop_disable_services
      lock_cpu_freq "1300MHz"
      echo_color $GREEN "[*] CPU 保守节能模式已启用。"
      ;;
    4)
      disable_gpu
      ;;
    5)
      enable_gpu
      ;;
    6)
      REQUIRE_CONFIRM
      restore_defaults
      ;;
    0)
      echo_color $CYAN "退出程序。"
      exit 0
      ;;
    *)
      echo_color $RED "无效选择，请重试。"
      ;;
  esac
}

# 脚本入口
check_root
while true; do
  menu
done
