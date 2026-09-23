#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# profile-sweep.sh — залежність сталої потужності від platform_profile.
# Міряє ФАКТИЧНИЙ draw (лічильник енергії 0x611, unit з 0x606), PL1/PL2 (0x610),
# частоту (scaling_cur_freq), темп пакета (coretemp hwmon).
# Governor тимчасово -> performance, повертається в кінці. Потрібен root + msr.
set -u
PPROF=/sys/firmware/acpi/platform_profile
OUT=$BASE/data/profile-sweep.csv
N=$(nproc)

# --- зберегти вихідний стан ---
ORIG_PROFILE=$(cat "$PPROF")
ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
echo "orig profile=$ORIG_PROFILE governor=$ORIG_GOV"

# --- знайти енергетичну одиницю (0x606 bits 12:8) ---
EU=$(rdmsr -0 0x606)
ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
EJ=$(python3 -c "print(1.0/(2**$ESU))")

# --- знайти coretemp package hwmon ---
PKG_TEMP=""
for h in /sys/class/hwmon/hwmon*; do
  [ -f "$h/name" ] || continue
  if [ "$(cat "$h/name")" = "coretemp" ]; then
    for l in "$h"/temp*_label; do
      [ -f "$l" ] || continue
      if grep -qi "Package" "$l"; then PKG_TEMP="${l%_label}_input"; break; fi
    done
  fi
  [ -n "$PKG_TEMP" ] && break
done
echo "pkg temp source: ${PKG_TEMP:-none}"

avg_freq(){ awk '{s+=$1;n++} END{if(n)printf "%.0f", s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; }
pkg_temp(){ [ -n "$PKG_TEMP" ] && awk '{printf "%.1f",$1/1000}' "$PKG_TEMP" || echo "na"; }

set_gov(){ for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$g" 2>/dev/null; done; }

echo "profile,t_s,draw_W,pl1_W,pl2_W,freq_MHz,pkg_C" > "$OUT"

for prof in low-power balanced performance; do
  echo "==== profile: $prof ===="
  echo "$prof" > "$PPROF" 2>/dev/null
  got=$(cat "$PPROF")
  echo "  set -> requested=$prof got=$got"
  set_gov performance
  # навантаження
  for i in $(seq 1 $N); do yes >/dev/null & done
  sleep 3   # прогрів під навантаженням
  e_prev=$(rdmsr -0 -d 0x611); t_prev=$(date +%s.%N)
  # 120 с / 5 с = 24 семпли
  for s in $(seq 1 24); do
    sleep 5
    e_now=$(rdmsr -0 -d 0x611); t_now=$(date +%s.%N)
    pl1=$(rdmsr -f 14:0 -d 0x610); pl2raw=$(rdmsr -0 -d 0x610)
    fr=$(avg_freq); tp=$(pkg_temp)
    read draw pl1w pl2w <<<"$(python3 -c "
de=($e_now-$e_prev)&0xffffffff
dt=$t_now-$t_prev
pl2=(0x$(printf %x $pl2raw)>>32)&0x7fff
print(f'{de*$EJ/dt:.1f} {$pl1*0.125:.1f} {pl2*0.125:.1f}')
")"
    echo "$prof,$((s*5)),$draw,$pl1w,$pl2w,$fr,$tp" | tee -a "$OUT"
    e_prev=$e_now; t_prev=$t_now
  done
  pkill -9 yes 2>/dev/null; wait 2>/dev/null
  sleep 3
done

# --- відновити ---
set_gov "$ORIG_GOV"
echo "$ORIG_PROFILE" > "$PPROF" 2>/dev/null
echo "restored profile=$(cat $PPROF) governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "CSV -> $OUT"
