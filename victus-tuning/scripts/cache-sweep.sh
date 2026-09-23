#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# cache-sweep.sh — свіп CACHE при зафіксованому CORE.
#
# ВАЖЛИВО про критерій. Для CORE індикатором був Vcore: він диктує напругу
# спільної шини VccIA, тому глибший offset -> нижча напруга.
# Для CACHE це НЕ працює: тест "хто тримає" тричі показав, що CACHE не рухає
# Vcore взагалі (дельти +2/+5 mV = шум). Але це НЕ означає, що його можна
# опускати нескінченно — Ring/LLC має власну межу стабільності і сиплеться
# САМ, не змінюючи напруги шини.
# Тому критерій для CACHE — ПОМИЛКИ, а не Vcore. І перевіряти треба обидві
# точки: all-core (Ring під навантаженням) + light-load boost.
set -u
CORE=${CORE_FIX:--165}
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOG="$BASE/logs/cache-sweep.log"
CSV="$BASE/data/uv-cache.csv"
CONF=/etc/throttled.conf

[ -f "$CSV" ] || echo "cache_mv,core_mv,vcore_mv,allcore_yc,boost_yc,verdict" > "$CSV"

setuv(){
python3 - "$CONF" "$CORE" "$1" <<'PY'
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
rc-service throttled restart >/dev/null 2>&1; sleep 4
echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null; sleep 3
}

yccheck(){   # <лог> -> PASS|FAIL_COMPUTE
    if grep -viE 'stop on error' "$1" \
       | grep -qiE 'exception|mismatch|: *failed|failed with|error\(s\) encountered|error encountered'
    then echo FAIL_COMPUTE
    elif [ "$(grep -c 'Passed' "$1")" -eq 0 ]; then echo FAIL_NORESULT
    else echo PASS; fi
}

for CACHE in "$@"; do
    echo "$(date +%T) ===== CACHE=$CACHE (CORE=$CORE) =====" | tee -a "$LOG"
    setuv "$CACHE"
    intel-undervolt read 2>&1 | head -3 | sed 's/^/  /' | tee -a "$LOG"

    # --- 1. all-core: Ring під повним навантаженням ---
    ( cd /opt/y-cruncher && timeout 340 ./y-cruncher stress -M:4G -D:45 -TL:300 </dev/null ) \
        > "$BASE/logs/yc-cache$CACHE-all.log" 2>&1
    A=$(yccheck "$BASE/logs/yc-cache$CACHE-all.log")
    V=$(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")
    echo "  all-core: $A (Passed=$(grep -c 'Passed' "$BASE/logs/yc-cache$CACHE-all.log"))" | tee -a "$LOG"

    # --- 2. light-load boost: Ring на високому бусті ---
    echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null; sleep 2
    ( cd /opt/y-cruncher && taskset -c 0,2 timeout 220 ./y-cruncher stress -M:2G -D:45 -TL:180 </dev/null ) \
        > "$BASE/logs/yc-cache$CACHE-boost.log" 2>&1
    B=$(yccheck "$BASE/logs/yc-cache$CACHE-boost.log")
    echo "  boost:    $B (Passed=$(grep -c 'Passed' "$BASE/logs/yc-cache$CACHE-boost.log"))" | tee -a "$LOG"

    VER=PASS
    [ "$A" != "PASS" ] && VER="$A(all)"
    [ "$B" != "PASS" ] && VER="$B(boost)"
    echo "$CACHE,$CORE,$V,$A,$B,$VER" >> "$CSV"
    echo "$(date +%T) ВЕРДИКТ CACHE=$CACHE: $VER" | tee -a "$LOG"
    sleep 15
done
echo "$(date +%T) === СВІП ЗАВЕРШЕНО ===" | tee -a "$LOG"
