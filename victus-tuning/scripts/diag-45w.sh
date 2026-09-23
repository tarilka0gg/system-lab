#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# diag-45w.sh — ловить МОМЕНТ просідання 80W -> 45W і знімає повний зліпок,
# щоб розрізнити: це CPU/BIOS (cTDP, RAPL) чи EC (PROCHOT, PSYS, зовнішній).
#
# Логіка розрізнення:
#   - MSR/MMIO RAPL показують 80W, а draw 45W  -> обмежує НЕ RAPL
#   - PERF_LIMIT_REASONS b0 (PROCHOT)          -> EC смикає PROCHOT (зовнішній)
#   - PERF_LIMIT_REASONS b9 (PL1)              -> RAPL/cTDP всередині CPU
#   - PSYS 0x65C активний і низький            -> платформний ліміт (EC/VRM)
set -u
BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT="$BASE/logs/diag-45w.log"

snap(){
python3 - "$1" <<'PY'
import subprocess,mmap,struct,os,sys
tag=sys.argv[1]
def r(m):
    try: return int(subprocess.check_output(['rdmsr','-0',m],stderr=subprocess.DEVNULL).decode().strip(),16)
    except: return None
cfg=open('/sys/bus/pci/devices/0000:00:00.0/config','rb').read(0x50)
base=(struct.unpack_from('<Q',cfg,0x48)[0])&~0x7fff
fd=os.open('/dev/mem',os.O_RDONLY)
def mmio(reg):
    a=base+reg; p=a&~0xfff; o=a&0xfff
    m=mmap.mmap(fd,0x1000,prot=mmap.PROT_READ,offset=p)
    v=struct.unpack_from('<Q',m,o)[0]; m.close(); return v
r610=r('0x610'); m59a0=mmio(0x59A0); psys=r('0x65C')
plr=r('0x690'); gplr=r('0x6B0'); therm=r('0x19C'); ctdp=r('0x64B'); pctl=r('0x1FC')
os.close(fd)
f=lambda x: f"PL1={(x&0x7fff)*0.125:.0f}W PL2={((x>>32)&0x7fff)*0.125:.0f}W"
print(f"--- {tag} ---")
print(f"  MSR 0x610   {f(r610)}")
print(f"  MMIO 0x59A0 {f(m59a0)}")
if psys is not None:
    print(f"  PSYS 0x65C  raw={psys:#x} PL={(psys&0x7fff)*0.125:.0f}W en={(psys>>15)&1}")
print(f"  POWER_CTL 0x1FC raw={pctl:#x} BD_PROCHOT_en(b0)={pctl&1}")
print(f"  CONFIG_TDP_CONTROL 0x64B = {ctdp}")
if plr is not None:
    names=[(0,'PROCHOT'),(1,'Thermal'),(4,'RSR'),(5,'Running avg thermal'),(6,'VR Therm Alert'),
           (7,'VR TDC'),(8,'Electrical design(EDP/IccMax)'),(9,'PL1'),(10,'PL2'),(11,'Turbo transition'),
           (12,'Max turbo limit'),(13,'Turbo attenuation')]
    act=[n for b,n in names if (plr>>b)&1]
    print(f"  CORE_PERF_LIMIT_REASONS 0x690 raw={plr:#x}")
    print(f"    АКТИВНІ: {', '.join(act) if act else '(жодної)'}")
if therm is not None:
    print(f"  THERM_STATUS 0x19C: PROCHOT_now(b2)={(therm>>2)&1} PROCHOT_log(b3)={(therm>>3)&1} "
          f"thermal(b0)={therm&1} нижче_TjMax={(therm>>16)&0x7f}C")
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
echo "переармування + старт навантаження" | tee -a "$OUT"
echo performance > /sys/firmware/acpi/platform_profile
sleep 3
stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 320s >/dev/null 2>&1 &
sleep 25

d=$(draw); echo "t=30s draw=${d}W" | tee -a "$OUT"
snap "ПІД ЧАС БУСТУ (80W)" | tee -a "$OUT"

echo "чекаю просідання..." | tee -a "$OUT"
for i in $(seq 1 40); do
  d=$(draw)
  fr=$(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
  echo "  t≈$((30+i*6))s draw=${d}W freq=${fr}MHz" | tee -a "$OUT"
  low=$(python3 -c "print(1 if $d < 60 else 0)")
  if [ "$low" = "1" ]; then
    echo ">>> ПРОСІДАННЯ ЗАФІКСОВАНО" | tee -a "$OUT"
    snap "ПІСЛЯ ПРОСІДАННЯ (45W)" | tee -a "$OUT"
    break
  fi
done
killall -9 stress-ng 2>/dev/null
echo "готово, лог: $OUT"
