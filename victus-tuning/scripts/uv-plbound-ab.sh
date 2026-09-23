#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# PL-bound A/B: міряє частоту all-core на навантаженні, що ВПИРАЄТЬСЯ в PL1.
# Змішане навантаження тягне лише ~60% PL1, тому не показує виграшу андервольту.
# Тут — чистий matrixprod, який вижимає draw до PL1.
#   uv-plbound-ab.sh <CORE_mV> <CACHE_mV> <мітка>
set -u
CORE=$1; CACHE=$2; LABEL=$3
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CSV="$BASE/data/uv-plbound.csv"
CONF=/etc/throttled.conf

[ -f "$CSV" ] || echo "label,core_mv,cache_mv,vcore_mv,freq_allcore_mhz,temp_c,draw_w,pl1_w" > "$CSV"

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
echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null   # переармування EC
sleep 3

applied=$(python3 - <<'PY'
import subprocess,time
def rd(p):
    subprocess.run(['wrmsr','-a','0x150',hex(0x8000001000000000|(p<<40))],check=True)
    time.sleep(0.05)
    v=int(subprocess.check_output(['rdmsr','-0','0x150']).decode().strip(),16)
    o=(v>>21)&0x7ff
    if o>=1024: o-=2048
    return round(o/1.024)
print(f"{rd(0)},{rd(2)}")
PY
)
echo "[$LABEL] mailbox=$applied (цільові $CORE,$CACHE)"

EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 90s >/dev/null 2>&1 &
SP=$!
sleep 40                      # повний розгін вікна PL1
e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N)
F=""; V=""; T=""
for s in 1 2 3 4 5; do
    sleep 8
    F="$F $(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)"
    V="$V $(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")"
    T="$T $(awk '{printf "%.0f",$1/1000}' /sys/class/hwmon/hwmon4/temp1_input)"
done
e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)
pl1=$(python3 -c "v=0x$(rdmsr -0 0x610); print(f'{(v&0x7fff)*0.125:.0f}')")
wait $SP 2>/dev/null; killall -9 stress-ng 2>/dev/null
sleep 2

python3 - "$LABEL" "$CORE" "$CACHE" "$V" "$F" "$T" "$e1" "$e2" "$t1" "$t2" "$ESU" "$pl1" "$CSV" <<'PY'
import sys
lab,core,cache,V,F,T=sys.argv[1:7]
def med(s):
    a=sorted(float(x) for x in s.split()) if s.strip() else [0]
    return a[len(a)//2]
de=(int(sys.argv[8],16)-int(sys.argv[7],16))&0xffffffff
dt=float(sys.argv[10])-float(sys.argv[9])
draw=de*(1.0/(2**int(sys.argv[11])))/dt if dt>0 else 0
pl1=sys.argv[12]; csv=sys.argv[13]
row=f"{lab},{core},{cache},{med(V):.0f},{med(F):.0f},{med(T):.0f},{draw:.1f},{pl1}"
open(csv,'a').write(row+"\n")
print(f"  -> Vcore={med(V):.0f}mV freq={med(F):.0f}MHz temp={med(T):.0f}C draw={draw:.1f}W (PL1={pl1}W)")
PY
