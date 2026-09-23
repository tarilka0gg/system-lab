#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# uv-campaign.sh — один крок кампанії андервольту.
#   uv-campaign.sh <CORE_mV> <CACHE_mV> <хвилин> <мітка>
# приклад: uv-campaign.sh -60 -50 15 phase1-step1
#
# Керує ЧЕРЕЗ throttled.conf [UNDERVOLT.AC] (не intel-undervolt) — один
# власник MSR 0x150, без гонки. throttled реаплаїть щосекунди.
#
# ПРИМІТКА про площини: mailbox має 5 площин — CORE(0) GPU(1) CACHE(2)
# UNCORE/SA(3) ANALOGIO(4). Окремої площини "E-core L2" немає; на Raptor Lake
# E-ядра живляться з тієї ж VccIA, що й P-ядра, і покриваються площиною CORE.
# (E-core L2 offset існує лише як BIOS-змінна CpuSetup 0x2B2, не рантайм.)
set -u

CORE=$1; CACHE=$2; MINUTES=$3; LABEL=$4
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CSV="$BASE/data/uv-campaign.csv"
STATUS="$BASE/data/uv-campaign.status"
CONF=/etc/throttled.conf

log(){ echo "$(date +%T) $*" | tee -a "$STATUS"; }

# --- CSV шапка ---
[ -f "$CSV" ] || echo "timestamp,label,core_mv,cache_mv,minutes,vcore_load_mv,freq_allcore_mhz,temp_c,draw_w,mce_new,whea_new,single_thread_ok,load_type,result" > "$CSV"

log "=== КРОК $LABEL: CORE=$CORE CACHE=$CACHE, ${MINUTES}хв ==="

# --- 1. запис у throttled.conf [UNDERVOLT.AC] ---
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

# --- 1b. переармування EC ---
# Без РЕАЛЬНОГО запису в platform_profile EC тримає власний занижений ліміт
# і заміри виходять нерепрезентативні (55W замість 80W, 2250 замість 3200 MHz).
echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
sleep 3

# --- 2. верифікація, що offset РЕАЛЬНО в mailbox ---
applied=$(python3 - <<'PY'
import subprocess,time
def rd(plane):
    subprocess.run(['wrmsr','-a','0x150',hex(0x8000001000000000|(plane<<40))],check=True)
    time.sleep(0.05)
    v=int(subprocess.check_output(['rdmsr','-0','0x150']).decode().strip(),16)
    o=(v>>21)&0x7ff
    if o>=1024: o-=2048
    return round(o/1.024)
print(f"{rd(0)},{rd(2)}")
PY
)
log "mailbox після застосування: CORE,CACHE = $applied (цільові $CORE,$CACHE)"

# --- 3. baseline лічильників помилок ---
# ВАЖЛИВО: grep -c друкує "0" І повертає код 1 -> "|| echo 0" дало б ДВА рядки
# і зламало б арифметику нижче. Тому без ||, з підстраховкою через ${:-0}.
mce0=$(dmesg 2>/dev/null | grep -icE 'mce:|machine check|hardware error'); mce0=${mce0:-0}
whea0=$(dmesg 2>/dev/null | grep -icE 'whea|corrected error'); whea0=${whea0:-0}

# --- 4. навантаження ---
EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
N=$(nproc)
log "запуск stress-ng: ${MINUTES}хв PL-bound навантаження (matrixprod)"
if command -v stress-ng >/dev/null; then
    # PL-bound стресор. Змішане навантаження (--cpu all + --vm) тягло лише ~60%
    # від PL1 і крутилось на 2462 MHz, тоді як PL-bound matrixprod вижимає
    # 80W/3553MHz — зовсім інша точка V/F, і саме там вилазить нестабільність.
    # Тестувати треба в тому режимі, в якому машина реально працюватиме.
    stress-ng --cpu $N --cpu-method matrixprod \
              --timeout ${MINUTES}m --metrics-brief > "$BASE/logs/uv-stress-$LABEL.log" 2>&1 &
    LOADPID=$!
else
    log "!! stress-ng немає, fallback на yes"
    for i in $(seq 1 $N); do yes >/dev/null & done
    LOADPID=""
fi

sleep 30   # прогрів + розгін вікна PL1
e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N)
V=""; F=""; T=""
SAMPLES=$(( MINUTES * 60 / 30 - 1 ))
[ "$SAMPLES" -lt 1 ] && SAMPLES=1
for s in $(seq 1 $SAMPLES); do
    # EC відкриває повні 80W лише ~2хв, далі жорстко сідає на 45W (cTDP level1).
    # Переармування на льоту повертає 80W/3550MHz — без цього тест сповзає
    # на низьку точку V/F і перестає перевіряти реальний робочий режим.
    if [ $(( (s - 1) % 3 )) -eq 0 ]; then
        echo performance > /sys/firmware/acpi/platform_profile 2>/dev/null
    fi
    sleep 30
    v=$(python3 -c "v=0x$(rdmsr -0 0x198); print(f'{((v>>32)&0xffff)/8192*1000:.0f}')")
    f=$(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
    t=$(awk '{printf "%.0f",$1/1000}' /sys/class/hwmon/hwmon4/temp1_input 2>/dev/null)
    V="$V $v"; F="$F $f"; T="$T $t"
done
e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)

[ -n "$LOADPID" ] && wait $LOADPID 2>/dev/null
pkill -9 yes 2>/dev/null; pkill -9 stress-ng 2>/dev/null
sleep 3

read vmed fmed tmed draw <<<"$(python3 - "$V" "$F" "$T" "$e1" "$e2" "$t1" "$t2" "$ESU" <<'PY'
import sys
def med(s):
    a=sorted(float(x) for x in s.split()) if s.strip() else [0]
    return a[len(a)//2]
V,F,T=sys.argv[1],sys.argv[2],sys.argv[3]
de=(int(sys.argv[5],16)-int(sys.argv[4],16))&0xffffffff
dt=float(sys.argv[7])-float(sys.argv[6])
draw=de*(1.0/(2**int(sys.argv[8])))/dt if dt>0 else 0
print(f"{med(V):.0f} {med(F):.0f} {med(T):.0f} {draw:.1f}")
PY
)"
log "під навантаженням: Vcore=${vmed}mV freq=${fmed}MHz temp=${tmed}C draw=${draw}W"

# --- 5. НИЗЬКОНАВАНТАЖЕНИЙ тест (Ring падає саме тут, не під повним) ---
log "низьконавантажений однопотоковий тест (Ring), 3хв"
st_ok=1
if command -v stress-ng >/dev/null; then
    timeout 200 stress-ng --cpu 1 --cpu-method all --timeout 180s > "$BASE/logs/uv-single-$LABEL.log" 2>&1
    [ $? -ne 0 ] && st_ok=0
else
    timeout 190 sh -c 'yes > /dev/null' ; :
fi
# плюс справжній простій — Ring-нестабільність вилазить в ідлі
sleep 60

# --- 6. перевірка помилок ---
mce1=$(dmesg 2>/dev/null | grep -icE 'mce:|machine check|hardware error'); mce1=${mce1:-0}
whea1=$(dmesg 2>/dev/null | grep -icE 'whea|corrected error'); whea1=${whea1:-0}
mce_new=$(( mce1 - mce0 )); whea_new=$(( whea1 - whea0 ))
log "нові MCE=$mce_new  WHEA/corrected=$whea_new  single-thread ok=$st_ok"
if [ "$mce_new" -gt 0 ] || [ "$whea_new" -gt 0 ]; then
    log "!!! ЗНАЙДЕНО АПАРАТНІ ПОМИЛКИ — деталі:"
    dmesg 2>/dev/null | grep -iE 'mce:|machine check|hardware error|whea|corrected error' | tail -10 | tee -a "$STATUS"
fi

RESULT=PASS
[ "$mce_new" -gt 0 ] && RESULT=FAIL_MCE
[ "$whea_new" -gt 0 ] && RESULT=FAIL_WHEA
[ "$st_ok" -eq 0 ] && RESULT=FAIL_SINGLE

echo "$(date +%FT%T),$LABEL,$CORE,$CACHE,$MINUTES,$vmed,$fmed,$tmed,$draw,$mce_new,$whea_new,$st_ok,PLBOUND,$RESULT" >> "$CSV"
log "=== РЕЗУЛЬТАТ $LABEL: $RESULT ==="
