#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# boost-test.sh <CORE> <CACHE> <хв> <мітка>
#
# Тест LIGHT-LOAD BOOST точки — тієї, яку вся попередня кампанія пропустила.
#
# Чому окремий тест: all-core matrixprod вантажить усі 24 потоки, і CPU сидить
# на ~3.9 GHz / 0.89 V. Але при ЛЕГКОМУ навантаженні (1-4 потоки) він буститься
# до 4.7-4.9 GHz / 1.03-1.13 V — зовсім інша точка кривої V/F. Саме там
# андервольт і сиплеться: -165/-175 давали Checksum Mismatch / Bottom word
# mismatch, тоді як all-core тест їх пропускав як "стабільні".
#
# Метод: y-cruncher прив'язаний через taskset до кількох P-ядер, решта вільна ->
# активні ядра йдуть у максимальний буст. Плюс переармування EC, щоб вікно
# високого бусту було відкрите.
set -u
CORE=$1; CACHE=$2; MIN=$3; LABEL=$4
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CONF=/etc/throttled.conf
LOG="$BASE/logs/boost-$LABEL.log"
CSV="$BASE/data/uv-boost.csv"

[ -f "$CSV" ] || echo "label,core_mv,cache_mv,threads,max_ratio,max_pcore_mhz,vcore_mv,ycruncher,verdict" > "$CSV"

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
rc-service throttled restart >/dev/null 2>&1; sleep 4
echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null; sleep 3

: > "$LOG"
echo "$(date +%T) === BOOST-ТЕСТ $LABEL: CORE=$CORE CACHE=$CACHE ===" | tee -a "$LOG"
intel-undervolt read 2>&1 | head -3 | sed 's/^/  /' | tee -a "$LOG"

# 4 потоки на P-ядрах (по одному на фізичне ядро, без HT-пар) -> високий буст
THREADS="0,2,4,6"
echo "$(date +%T) y-cruncher на ядрах $THREADS, ${MIN}хв" | tee -a "$LOG"

( cd /opt/y-cruncher && taskset -c $THREADS timeout $((MIN*60+90)) \
    ./y-cruncher stress -M:2G -D:45 -TL:$((MIN*60)) </dev/null ) \
    > "$BASE/logs/yc-boost-$LABEL.log" 2>&1 &
YCPID=$!

sleep 20
MR=0; MF=0; V=""
for i in $(seq 1 $((MIN*4))); do
    [ $(( (i-1) % 6 )) -eq 0 ] && echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
    sleep 15
    r=$(python3 -c "v=0x$(rdmsr -0 0x198); print((v>>8)&0xff)")
    f=$(for c in 0 2 4 6; do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | sort -rn | head -1 | awk '{printf "%.0f",$1/1000}')
    v=$(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")
    [ "$r" -gt "$MR" ] 2>/dev/null && MR=$r
    [ "$f" -gt "$MF" ] 2>/dev/null && MF=$f
    V="$V $v"
    kill -0 $YCPID 2>/dev/null || break
done
wait $YCPID 2>/dev/null
killall -9 y-cruncher 2>/dev/null; sleep 2

VM=$(python3 -c "
a=sorted(float(x) for x in '$V'.split()) if '$V'.strip() else [0]
print(f'{a[len(a)//2]:.0f}')")

YC=PASS
if grep -viE 'stop on error' "$BASE/logs/yc-boost-$LABEL.log" \
   | grep -qiE 'exception|mismatch|: *failed|failed with|error\(s\) encountered|error encountered'
then YC=FAIL_COMPUTE; fi
[ "$(grep -c 'Passed' "$BASE/logs/yc-boost-$LABEL.log")" -eq 0 ] && YC=FAIL_NORESULT

echo "$(date +%T) max ratio=$MR max P-core=${MF}MHz Vcore(мед)=${VM}mV" | tee -a "$LOG"
echo "$(date +%T) y-cruncher: $YC (Passed=$(grep -c 'Passed' "$BASE/logs/yc-boost-$LABEL.log"))" | tee -a "$LOG"
[ "$YC" != "PASS" ] && sed 's/\x1b\[[0-9;]*m//g' "$BASE/logs/yc-boost-$LABEL.log" \
    | grep -iE 'exception|mismatch|error\(s\) encountered' | head -3 | tee -a "$LOG"

echo "$LABEL,$CORE,$CACHE,4,$MR,$MF,$VM,$YC,$YC" >> "$CSV"
echo "$(date +%T) === ВЕРДИКТ $LABEL: $YC ===" | tee -a "$LOG"
