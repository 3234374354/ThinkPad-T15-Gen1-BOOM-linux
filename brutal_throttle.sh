#!/usr/bin/env bash
# brutal_throttle.sh
# 极端：初始化/极限模式/电池保守模式/还原
# 说明：在 ThinkPad T15 等系统上尽可能暴力地关闭温控、锁频、强制显卡满血。
# 风险：极高。请在外接电源、外置风扇、并理解风险的情况下运行。
set -e

REQUIRE_CONFIRM() {
  echo
  echo "!!! 非常重要 !!!"
  echo "你将执行高风险操作，可能导致不可逆硬件损伤、数据丢失、系统不稳定。"
  read -p "如果你非常确定要继续，请输入大写 YES : " CONF
  if [[ "$CONF" != "YES" ]]; then
    echo "放弃。"
    exit 1
  fi
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请以 root 身份运行： sudo $0"
    exit 1
  fi
}

install_deps() {
  echo "[*] 安装必要依赖（cpufrequtils, nvidia-utils/driver, util-linux 等）..."
  apt update || true
  apt install -y cpufrequtils jq pciutils || true
  # 尝试安装 nvidia 工具（若系统已安装则跳过）
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "[*] 已检测到 nvidia-smi。"
  else
    echo "[!] 未检测到 nvidia-smi（或未安装 NVIDIA 驱动）。若无 NVIDIA 驱动，GPU 操作会跳过。"
  fi
}

stop_disable_services() {
  echo "[*] 停止并禁用常见电源/热管理服务..."
  for svc in thermald power-profiles-daemon tlp; do
    if systemctl list-unit-files | grep -q "$svc"; then
      systemctl stop "$svc" || true
      systemctl disable "$svc" || true
      echo "  - $svc stopped+disabled"
    fi
  done
}

blacklist_thermal_modules() {
  echo "[*] 尝试卸载并黑名单热相关内核模块（intel_rapl intel_powerclamp thermal）..."
  for mod in intel_rapl intel_powerclamp intel_pmc_core powerclamp; do
    if lsmod | grep -q "^$mod"; then
      modprobe -r "$mod" || true
      echo "  - rmmod $mod"
    fi
  done

  BLFILE=/etc/modprobe.d/99-brutal-thermal-blacklist.conf
  echo "blacklist intel_rapl" > "$BLFILE"
  echo "blacklist intel_powerclamp" >> "$BLFILE"
  echo "blacklist powerclamp" >> "$BLFILE"
  echo "blacklist thermal" >> "$BLFILE"
  echo "[*] 已写 $BLFILE，注意可能需要 update-initramfs -u 并重启完全生效（脚本不强制重启）。"
}

# CPU: set governor and lock freq to provided value (kHz or in MHz with m suffix)
lock_cpu_freq() {
  TARGET="$1"
  echo "[*] 尝试将 CPU 频率锁定为 $TARGET ..."
  # 如果传入以 MHz 结尾，转换为 kHz
  if [[ "$TARGET" =~ ^[0-9]+(\.[0-9]+)?MHz$ ]]; then
    m=${TARGET%MHz}
    k=$(( ${m/.*} * 1000 ))
    TARGET_KHZ="${k}000"
  elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    TARGET_KHZ="${TARGET}000"
  else
    TARGET_KHZ="$TARGET"
  fi

  # 使用 cpufreq-set（cpufrequtils）或直接写 sysfs
  if command -v cpufreq-set >/dev/null 2>&1; then
    echo "[*] 使用 cpufreq-set 对所有核心设置频率..."
    cpufreq-set -r -g performance || true
    cpus=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    # 尝试设置为可用的最大值或指定值
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      cpu_id=$(basename "$c")
      if [[ -f "$c/cpufreq/scaling_setspeed" ]]; then
        echo "$TARGET_KHZ" > "$c/cpufreq/scaling_setspeed" || true
      else
        echo "[!] $cpu_id 不支持 scaling_setspeed，尝试写 min/max..."
        echo "$TARGET_KHZ" > "$c/cpufreq/scaling_min_freq" || true
        echo "$TARGET_KHZ" > "$c/cpufreq/scaling_max_freq" || true
      fi
    done
  else
    echo "[!] 系统没有 cpufreq-set，尝试直接写 sysfs..."
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
      if [[ -d "$c/cpufreq" ]]; then
        echo "$TARGET_KHZ" > "$c/cpufreq/scaling_min_freq" || true
        echo "$TARGET_KHZ" > "$c/cpufreq/scaling_max_freq" || true
      fi
    done
  fi

  echo "[*] 已尝试锁定 CPU 频率。检查： cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
}

# GPU extreme mode: persistence + lock to highest available clocks + set power limit to max
gpu_extreme_mode() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[!] 未检测到 nvidia-smi，跳过 GPU 操作。"
    return
  fi
  echo "[*] GPU: 启用持久化模式..."
  nvidia-smi -pm 1 || true

  # 读取最大可用 power limit (watts)
  MAX_POW=$(nvidia-smi -q -d POWER | awk -F: '/Max Power Limit/ {print $2+0; exit}')
  if [[ -n "$MAX_POW" ]]; then
    echo "[*] GPU: 将功率上限设为最大值 ${MAX_POW}W ..."
    nvidia-smi -pl "${MAX_POW}" || true
  fi

  # 读取最高 Graphics Clock 和 Memory Clock（挑第一个支持的最高值）
  HIGH_GRAPHIC=$(nvidia-smi -q -d SUPPORTED_CLOCKS | awk '/Graphics Clocks/ {getline; print $1; exit}' | tr -d 'MHz,')
  HIGH_MEM=$(nvidia-smi -q -d SUPPORTED_CLOCKS | awk '/Memory Clocks/ {getline; print $1; exit}' | tr -d 'MHz,')
  # fallback: 使用当前 max
  if [[ -z "$HIGH_GRAPHIC" ]]; then
    HIGH_GRAPHIC=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits | head -n1)
  fi
  if [[ -z "$HIGH_MEM" ]]; then
    HIGH_MEM=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits | head -n1)
  fi

  if [[ -n "$HIGH_GRAPHIC" && -n "$HIGH_MEM" ]]; then
    echo "[*] GPU: 锁定 Graphics=$HIGH_GRAPHIC MHz, Memory=$HIGH_MEM MHz ..."
    nvidia-smi -lgc ${HIGH_GRAPHIC},${HIGH_GRAPHIC} || true
    nvidia-smi -lmc ${HIGH_MEM},${HIGH_MEM} || true
  else
    echo "[!] 无法检测最高频，跳过锁频。"
  fi

  echo "[*] GPU 極限模式已应用（若驱动支持）。请监控温度。"
}

# GPU conservative mode: lower clocks and power limit (50% of max)
gpu_conservative_mode() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[!] 未检测到 nvidia-smi，跳过 GPU 操作。"
    return
  fi
  echo "[*] GPU: 启用持久化模式..."
  nvidia-smi -pm 1 || true

  MAX_POW=$(nvidia-smi -q -d POWER | awk -F: '/Max Power Limit/ {print $2+0; exit}')
  if [[ -n "$MAX_POW" ]]; then
    NEW_POW=$(awk "BEGIN{printf \"%d\", (${MAX_POW}*0.5)}")
    echo "[*] GPU: 将功率上限设为 ${NEW_POW}W （约50%）..."
    nvidia-smi -pl "${NEW_POW}" || true
  fi

  # 选择保守频率（取支持频率中靠下的一个）
  LOW_GRAPHIC=$(nvidia-smi -q -d SUPPORTED_CLOCKS | awk '/Graphics Clocks/ {getline; getline; print $1; exit}' | tr -d 'MHz,')
  LOW_MEM=$(nvidia-smi -q -d SUPPORTED_CLOCKS | awk '/Memory Clocks/ {getline; getline; print $1; exit}' | tr -d 'MHz,')
  if [[ -z "$LOW_GRAPHIC" ]]; then
    LOW_GRAPHIC=$(nvidia-smi --query-gpu=clocks.min.graphics --format=csv,noheader,nounits | head -n1)
  fi
  if [[ -z "$LOW_MEM" ]]; then
    LOW_MEM=$(nvidia-smi --query-gpu=clocks.min.memory --format=csv,noheader,nounits | head -n1)
  fi

  if [[ -n "$LOW_GRAPHIC" && -n "$LOW_MEM" ]]; then
    echo "[*] GPU: 锁定 Graphics=${LOW_GRAPHIC} MHz, Memory=${LOW_MEM} MHz ..."
    nvidia-smi -lgc ${LOW_GRAPHIC},${LOW_GRAPHIC} || true
    nvidia-smi -lmc ${LOW_MEM},${LOW_MEM} || true
  else
    echo "[!] 无法检测低频选项，跳过。"
  fi

  echo "[*] GPU 保守模式已应用。"
}

restore_defaults() {
  echo "[*] 恢复默认设置：启用服务、移除黑名单、重载内核模块、恢复 GPU 默认。"
  for svc in thermald power-profiles-daemon tlp; do
    if systemctl list-unit-files | grep -q "$svc"; then
      systemctl enable "$svc" || true
      systemctl start "$svc" || true
      echo "  - $svc enabled+started"
    fi
  done

  BLFILE=/etc/modprobe.d/99-brutal-thermal-blacklist.conf
  if [[ -f "$BLFILE" ]]; then
    rm -f "$BLFILE"
    echo "[*] 已移除 $BLFILE"
    update-initramfs -u || true
  fi

  # 试着重载被 rmmod 卸载的模块
  for mod in intel_rapl intel_powerclamp powerclamp thermal; do
    modprobe "$mod" || true
  done

  if command -v nvidia-smi >/dev/null 2>&1; then
    # 解除 locks: reset power limit to default (set to max then let driver manage)
    DEFAULT_MAX=$(nvidia-smi -q -d POWER | awk -F: '/Max Power Limit/ {print $2+0; exit}')
    if [[ -n "$DEFAULT_MAX" ]]; then
      nvidia-smi -pl "$DEFAULT_MAX" || true
    fi
    # 解除 locked clocks
    nvidia-smi -rgc || true
    nvidia-smi -rmm || true
  fi

  # Reset cpu freq to ondemand or intel_pstate
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    if [[ -d "$c/cpufreq" ]]; then
      echo "ondemand" > "$c/cpufreq/scaling_governor" || true
      # Remove min/max clamping if present
      echo 0 > "$c/cpufreq/scaling_min_freq" 2>/dev/null || true
      echo 0 > "$c/cpufreq/scaling_max_freq" 2>/dev/null || true
    fi
  done

  echo "[*] 尝试恢复完成。请重启系统以确保所有更改完全生效。"
}

menu() {
  cat <<EOF
===== 极端温控脚本菜单 =====
1) 初始化：安装依赖、停止/禁用热管理服务、黑名单热模块（需要确认）
2) 极限模式（插电用）：
     - CPU 尽量锁定到可用最大频率（performance）
     - 强制解除内核热限、卸载热模块（如能卸载）
     - GPU: 持久化 + 锁定最高 Graphics/Memory clocks + 设置功率到最大
3) 保守模式（接电池用）：
     - CPU 锁定为 1300MHz
     - GPU 设置为保守功率（约50% max），降低频率
4) 还原：恢复服务/移除黑名单/恢复 GPU/CPU 默认设置
0) 退出
============================
EOF
  read -p "选择 (0-4): " CHOICE
  case "$CHOICE" in
    1)
      REQUIRE_CONFIRM
      install_deps
      stop_disable_services
      blacklist_thermal_modules
      echo "[*] 初始化完成（部分改动可能需要重启或 update-initramfs -u）"
      ;;
    2)
      REQUIRE_CONFIRM
      echo "[*] 极限模式启动：先卸载热模块，再锁CPU到最高，再把GPU逼到最满血..."
      stop_disable_services
      blacklist_thermal_modules
      # CPU：尝试读取 cpuinfo_max_freq
      if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        MAXKHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        # convert to MHz for display
        MAXMHZ=$((MAXKHZ/1000))
        lock_cpu_freq "${MAXMHZ}MHz"
      else
        echo "[!] 无法读取 CPU 最大频率，尝试设置为 performance 模式并不改频率。"
        for c in /sys/devices/system/cpu/cpu[0-9]*; do
          if [[ -d "$c/cpufreq" ]]; then
            echo performance > "$c/cpufreq/scaling_governor" || true
          fi
        done
      fi
      gpu_extreme_mode
      echo "[*] 极限模式已尝试应用。请立即监控温度（watch -n1 nvidia-smi; watch -n1 cat /sys/class/thermal/thermal_zone0/temp）"
      ;;
    3)
      REQUIRE_CONFIRM
      echo "[*] 保守模式：CPU 1300MHz，GPU 保守功耗..."
      stop_disable_services
      lock_cpu_freq "1300MHz"
      gpu_conservative_mode
      echo "[*] 保守模式应用完毕。"
      ;;
    4)
      REQUIRE_CONFIRM
      restore_defaults
      ;;
    0)
      echo "退出。"
      exit 0
      ;;
    *)
      echo "无效选择。"
      ;;
  esac
}

# 主流程
check_root
menu
