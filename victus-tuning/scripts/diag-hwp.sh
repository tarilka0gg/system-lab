#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# diag-hwp.sh — ловить просідання і порівнює HWP / turbo-ratio до і після.
# Гіпотеза: RAPL/PROCHOT/PSYS/тепло виключені, отже обмежують ЧАСТОТУ напряму —
# найімовірніше через HWP (Speed Shift) або TURBO_RATIO_LIMIT.
set -u
OUT=$BASE/logs/diag-hwp.log

snap(){
python3 - "$1" <<'PY'
import subprocess,sys
tag=sys.argv[1]
def r(m,cpu='0'):
    try: return int(subprocess.check_output(['rdmsr','-0','-p',cpu,m],stderr=subprocess.DEVNULL).decode().strip(),16)
    except: return None
print(f"--- {tag} ---")
cap=r('0x771'); req=r('0x774'); pm=r('0x770')
if cap is not None:
    print(f"  HWP_CAPABILITIES 0x771 raw={cap:#x}")
    print(f"    highest={cap&0xff} guaranteed={(cap>>8)&0xff} efficient={(cap>>16)&0xff} lowest={(cap>>24)&0xff}")
if req is not None:
    print(f"  HWP_REQUEST 0x774 raw={req:#x}")
    print(f"    min={req&0xff} max={(req>>8)&0xff} desired={(req>>16)&0xff} epp={(req>>24)&0xff}")
print(f"  PM_ENABLE 0x770 = {pm}")
for m,n in [('0x1AD','TURBO_RATIO_LIMIT'),('0x1AE','TURBO_RATIO_LIMIT_CORES'),
            ('0x64C','TURBO_ACTIVATION_RATIO'),('0x1A2','TEMPERATURE_TARGET'),
            ('0x198','PERF_STATUS'),('0x199','PERF_CTL')]:
    v=r(m)
    if v is None: continue
    if m=='0x198':
        print(f"  {m} {n}: raw={v:#x} ratio={(v>>8)&0xff} vcore={((v>>32)&0xffff)/8192*1000:.0f}mV")
    elif m=='0x1A2':
        print(f"  {m} {n}: TjMax={(v>>16)&0xff}C TccOffset={(v>>24)&0x3f}")
    else:
        print(f"  {m} {n}: raw={v:#x}")
# максимальна дозволена частота з cpufreq
import glob
mx=set()
for f in glob.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq'):
    mx.add(open(f).read().strip())
print(f"  scaling_max_freq (унікальні): {sorted(mx)}")
PY
}

EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
draw(){
  local e1 t1 e2 t2
  e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N); sleep 5
  e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)
  python3 -c "
de=(0x$e2-0x$e1)&0xffffffff
print(f'{de*(1.0/(2**$ESU))/($t2-$t1):.1f}')"
}

: > "$OUT"
echo performance > /sys/firmware/acpi/platform_profile; sleep 3
stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 320s >/dev/null 2>&1 &
sleep 25
snap "БУСТ 80W" | tee -a "$OUT"
echo "чекаю просідання..." | tee -a "$OUT"
for i in $(seq 1 45); do
  d=$(draw)
  fr=$(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
  echo "  t≈$((30+i*6))s draw=${d}W freq=${fr}MHz" | tee -a "$OUT"
  if [ "$(python3 -c "print(1 if $d < 60 else 0)")" = "1" ]; then
    echo ">>> ПРОСІДАННЯ" | tee -a "$OUT"
    snap "ПІСЛЯ ПРОСІДАННЯ 45W" | tee -a "$OUT"
    break
  fi
done
killall -9 stress-ng 2>/dev/null
