#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# who-holds.sh <CORE_base> <CACHE_base>
#
# Визначає, ЯКИЙ домен диктує напругу шини VccIA у поточній точці.
# P-ядра, E-ядра і Ring/LLC живляться з однієї шини; її напруга = МАКСИМУМ
# із запитів усіх доменів. Тому опускати обидва однаково — марно, щойно один
# з них стає обмежувачем: подальший андервольт другого нічого не дає.
#
# Метод: три коротких заміри Vcore під PL-bound навантаженням —
#   base, (CORE-20), (CACHE-20). Хто сильніше рухає Vcore — той і тримає.
set -u
CB=$1; KB=$2
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CONF=/etc/throttled.conf
LOG="$BASE/logs/who-holds.log"

setuv(){
python3 - "$CONF" "$1" "$2" <<'PY'
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
echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
sleep 3
}

# короткий замір медіани Vcore під PL-bound (з переармуванням)
probe(){
    local core=$1 cache=$2 tag=$3
    setuv "$core" "$cache"
    stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 200s >/dev/null 2>&1 &
    sleep 35
    local V="" F="" i
    for i in 1 2 3 4 5 6 7 8; do
        [ $(( (i-1) % 3 )) -eq 0 ] && echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
        sleep 15
        V="$V $(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")"
        F="$F $(for c in $(seq 0 15); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}')"
    done
    killall -9 stress-ng 2>/dev/null; sleep 3
    python3 - "$V" "$F" <<'PY'
import sys
def med(s):
    a=sorted(float(x) for x in s.split()) if s.strip() else [0]
    return a[len(a)//2]
print(f"{med(sys.argv[1]):.0f} {med(sys.argv[2]):.0f}")
PY
}

echo "=== ХТО ТРИМАЄ у точці CORE=$CB CACHE=$KB ===" | tee -a "$LOG"
read v0 f0 <<<"$(probe "$CB" "$KB" base)"
echo "  base       CORE=$CB CACHE=$KB   -> Vcore=${v0}mV  P-freq=${f0}MHz" | tee -a "$LOG"

read vc fc <<<"$(probe $((CB-20)) "$KB" corelow)"
echo "  CORE -20   CORE=$((CB-20)) CACHE=$KB   -> Vcore=${vc}mV  P-freq=${fc}MHz" | tee -a "$LOG"

read vk fk <<<"$(probe "$CB" $((KB-20)) cachelow)"
echo "  CACHE -20  CORE=$CB CACHE=$((KB-20))   -> Vcore=${vk}mV  P-freq=${fk}MHz" | tee -a "$LOG"

python3 - "$v0" "$vc" "$vk" "$CB" "$KB" <<'PY' | tee -a "$LOG"
import sys
v0,vc,vk=float(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3])
cb,kb=sys.argv[4],sys.argv[5]
dc,dk=v0-vc,v0-vk
print(f"\n  дельта від CORE -20 : {dc:+.0f} mV")
print(f"  дельта від CACHE -20: {dk:+.0f} mV")
NOISE=3
if dc<=NOISE and dk<=NOISE:
    print(f"  => ЖОДЕН не рухає Vcore (обидві дельти <= {NOISE}mV шуму)")
    print(f"     ДНО VRM — асиметрія вичерпана, стоп-умова")
elif dc>dk+NOISE:
    print(f"  => ТРИМАЄ CORE. Наступний крок: CORE={int(cb)-20}, CACHE={kb} (не чіпати)")
elif dk>dc+NOISE:
    print(f"  => ТРИМАЄ CACHE. Наступний крок: CORE={cb} (не чіпати), CACHE={int(kb)-20}")
else:
    print(f"  => обидва рухають однаково — шина ділиться, опускати РАЗОМ")
PY
