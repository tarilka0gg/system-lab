#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# validate.sh <CORE> <CACHE> <хв_ycruncher> <хв_plbound> <хв_ідлу> <мітка>
#
# Строга валідація асиметричної точки. Три різні класи перевірки, бо вони
# ловлять РІЗНЕ:
#   y-cruncher  — обчислювальна коректність (тиха нестабільність без крашу).
#                 stress-ng цього не гарантує: він вантажить, але не звіряє
#                 результат так строго.
#   PL-bound    — висока точка V/F (80W, ~3900 MHz P-ядра), де вилазить
#                 нестабільність ядер під напругою.
#   ідл         — Ring/cache падає саме в простої, окремо від навантаження.
# WHEA/MCE перевіряється після кожного етапу — correctable-помилки з'являються
# ДО фактичного зависання.
set -u
CORE=$1; CACHE=$2; YCM=$3; PLM=$4; IDLEM=$5; LABEL=$6
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CSV="$BASE/data/uv-asym.csv"
LOG="$BASE/logs/validate-$LABEL.log"
CONF=/etc/throttled.conf
YC=/opt/y-cruncher/y-cruncher

log(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
errcount(){ local n; n=$(dmesg 2>/dev/null | grep -icE 'mce:|machine check|hardware error|whea|corrected error'); echo "${n:-0}"; }

find_cpu_temp(){
    local h l
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "coretemp" ] || continue
        for l in "$h"/temp*_label; do
            grep -qi 'Package' "$l" 2>/dev/null && { echo "${l%_label}_input"; return 0; }
        done
    done
    return 1
}
CPU_TEMP_PATH=$(find_cpu_temp || true)
[ -z "$CPU_TEMP_PATH" ] && { echo "FATAL: coretemp Package hwmon не знайдено" >&2; exit 1; }

[ -f "$CSV" ] || echo "label,core_mv,cache_mv,dictates,vcore_mv,pcore_mhz,temp_c,draw_w,ycruncher,whea,verdict" > "$CSV"

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
: > "$LOG"
log "=== ВАЛІДАЦІЯ $LABEL: CORE=$CORE CACHE=$CACHE (mailbox=$applied) ==="
e0=$(errcount)

# --- 1. y-cruncher: обчислювальна коректність ---
YC_RES=PASS
if [ -n "$YCM" ] && [ "$YCM" -gt 0 ]; then
    log "y-cruncher ${YCM}хв (correctness)"
    ( cd /opt/y-cruncher && timeout $((YCM*60+120)) "$YC" stress -M:4G -D:60 -TL:$((YCM*60)) </dev/null ) \
        > "$BASE/logs/yc-$LABEL.log" 2>&1
    rc=$?
    # Детект збою. ДВІ пастки, на які я вже наступив:
    #  1) y-cruncher друкує рядок конфігурації "Stop on Error: Enabled" —
    #     наївний grep на 'error' дає ХИБНИЙ FAIL. Тому цей рядок виключаємо.
    #  2) реальні збої пишуться у РІЗНОМУ регістрі:
    #     "Bottom word mismatch." / "Running SFTv4: Failed" /
    #     "Stress test failed with 1 error." / "AlgorithmFailedException"
    #     Регістрозалежний патерн їх ПРОПУСКАЄ -> хибний PASS. Тільки -i.
    if grep -viE 'stop on error' "$BASE/logs/yc-$LABEL.log" \
       | grep -qiE 'exception|mismatch|: *failed|failed with|error\(s\) encountered|error encountered'
    then YC_RES=FAIL_COMPUTE; fi
    [ "$(grep -c 'Passed' "$BASE/logs/yc-$LABEL.log")" -eq 0 ] && YC_RES=FAIL_NORESULT
    # Передчасне завершення — теж збій: "Stop on Error" зупиняє тест на помилці,
    # тому прогін коротший за заданий = підозра, навіть якщо rc=0.
    if [ "$YC_RES" = "PASS" ] && [ "$(grep -c 'Passed' "$BASE/logs/yc-$LABEL.log")" -lt "$YCM" ]; then
        YC_RES=FAIL_EARLY_EXIT
    fi
    [ $rc -ne 0 ] && [ $rc -ne 124 ] && YC_RES=FAIL_CRASH
    log "  y-cruncher: $YC_RES (rc=$rc, Passed=$(grep -c 'Passed' "$BASE/logs/yc-$LABEL.log"))"
fi

# --- 2. PL-bound: висока точка V/F ---
EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
log "PL-bound ${PLM}хв (matrixprod, переармування кожні 90с)"
stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout ${PLM}m >/dev/null 2>&1 &
sleep 35
e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N)
V=""; F=""; T=""
S=$(( PLM * 60 / 30 - 1 )); [ "$S" -lt 1 ] && S=1
for s in $(seq 1 $S); do
    [ $(( (s-1) % 3 )) -eq 0 ] && echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
    sleep 30
    V="$V $(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")"
    F="$F $(for c in $(seq 0 15); do cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq; done | awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}')"
    T="$T $(awk '{printf "%.0f",$1/1000}' "$CPU_TEMP_PATH")"
done
e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)
killall -9 stress-ng 2>/dev/null; sleep 3
read vmed fmed tmed draw <<<"$(python3 - "$V" "$F" "$T" "$e1" "$e2" "$t1" "$t2" "$ESU" <<'PY'
import sys
def med(s):
    a=sorted(float(x) for x in s.split()) if s.strip() else [0]
    return a[len(a)//2]
de=(int(sys.argv[5],16)-int(sys.argv[4],16))&0xffffffff
dt=float(sys.argv[7])-float(sys.argv[6])
print(f"{med(sys.argv[1]):.0f} {med(sys.argv[2]):.0f} {med(sys.argv[3]):.0f} {de*(1.0/(2**int(sys.argv[8])))/dt if dt>0 else 0:.1f}")
PY
)"
log "  Vcore=${vmed}mV P-freq=${fmed}MHz temp=${tmed}C draw=${draw}W"

# --- 3. ідл: Ring падає саме тут ---
if [ "$IDLEM" -gt 0 ]; then
    log "ідл ${IDLEM}хв (Ring-нестабільність)"
    sleep $((IDLEM*60))
fi

e3=$(errcount); whea=$(( e3 - e0 ))
log "нові WHEA/MCE: $whea"
[ "$whea" -gt 0 ] && dmesg | grep -iE 'mce:|hardware error|whea|corrected' | tail -8 | tee -a "$LOG"

VERDICT=PASS
[ "$YC_RES" != "PASS" ] && VERDICT=$YC_RES
[ "$whea" -gt 0 ] && VERDICT=FAIL_WHEA
echo "$LABEL,$CORE,$CACHE,,$vmed,$fmed,$tmed,$draw,$YC_RES,$whea,$VERDICT" >> "$CSV"
log "=== ВЕРДИКТ $LABEL: $VERDICT ==="
