#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# measure-pcore.sh <CORE_mV> <CACHE_mV> <мітка>
# Міряє частоту ОКРЕМО по P-ядрах і E-ядрах на PL-bound навантаженні.
# Середнє по всіх 24 потоках занижує показник, бо E-ядра мають стелю 3.7 GHz,
# а P-ядра 5.0-5.2 GHz — змішувати їх в одну цифру некоректно.
set -u
CORE=$1; CACHE=$2; LABEL=$3
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CSV="$BASE/data/uv-percore.csv"
CONF=/etc/throttled.conf

[ -f "$CSV" ] || echo "label,core_mv,cache_mv,pcore_avg_mhz,pcore_max_mhz,ecore_avg_mhz,allcore_avg_mhz,vcore_mv,temp_c,draw_w" > "$CSV"

python3 - "$CONF" "$CORE" "$CACHE" <<'PY'
import re,sys
p,core,cache=sys.argv[1],sys.argv[2],sys.argv[3]
lines=open(p).read().splitlines(); sec=None; out=[]
for ln in lines:
    m=re.match(r'\s*\[(.+)\]\s*$', ln)
    if m: sec=m.group(1)
    if sec=='UNDERVOLT.AC':
        if re.match(r'\s*CORE\s*:\s*-?\d+', ln):  ln=f"CORE: {core}"
        if re.match(r'\s*CACHE\s*:\s*-?\d+', ln): ln=f"CACHE: {cache}"
    out.append(ln)
open(p,'w').write('\n'.join(out)+'\n')
PY
rc-service throttled restart >/dev/null 2>&1
sleep 4
echo performance > /sys/firmware/acpi/platform_profile; sleep 3

EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 130s >/dev/null 2>&1 &
sleep 35
e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N)
PA=""; PM=""; EA=""; AA=""; V=""; T=""
for s in 1 2 3 4 5 6; do
    sleep 10
    # P-ядра = cpu0-15, E-ядра = cpu16-23
    pa=$(for c in $(seq 0 15); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}')
    pm=$(for c in $(seq 0 15); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | sort -rn | head -1 | awk '{printf "%.0f",$1/1000}')
    ea=$(for c in $(seq 16 23); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}')
    aa=$(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
    v=$(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")
    t=$(awk '{printf "%.0f",$1/1000}' /sys/class/hwmon/hwmon4/temp1_input)
    PA="$PA $pa"; PM="$PM $pm"; EA="$EA $ea"; AA="$AA $aa"; V="$V $v"; T="$T $t"
done
e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)
killall -9 stress-ng 2>/dev/null; sleep 2

python3 - "$LABEL" "$CORE" "$CACHE" "$PA" "$PM" "$EA" "$AA" "$V" "$T" "$e1" "$e2" "$t1" "$t2" "$ESU" "$CSV" <<'PY'
import sys
lab,core,cache=sys.argv[1:4]
def med(s):
    a=sorted(float(x) for x in s.split()) if s.strip() else [0]
    return a[len(a)//2]
PA,PM,EA,AA,V,T=[med(sys.argv[i]) for i in range(4,10)]
de=(int(sys.argv[11],16)-int(sys.argv[10],16))&0xffffffff
dt=float(sys.argv[13])-float(sys.argv[12])
draw=de*(1.0/(2**int(sys.argv[14])))/dt if dt>0 else 0
csv=sys.argv[15]
open(csv,'a').write(f"{lab},{core},{cache},{PA:.0f},{PM:.0f},{EA:.0f},{AA:.0f},{V:.0f},{T:.0f},{draw:.1f}\n")
print(f"  [{lab}] P-ядра avg={PA:.0f} max={PM:.0f} | E-ядра avg={EA:.0f} | усі={AA:.0f} MHz")
print(f"          Vcore={V:.0f}mV temp={T:.0f}C draw={draw:.1f}W")
PY
