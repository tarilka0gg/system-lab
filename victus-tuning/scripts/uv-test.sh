#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/board-guard.sh"
# uv-test.sh <label> — 60с навантаження, медіана Vcore(0x198 b47:32/8192), freq, draw.
set -u
label="$1"
EU=$(rdmsr -0 0x606); ESU=$(python3 -c "print((0x$EU>>8)&0x1f)")
N=$(nproc)
for i in $(seq 1 "$N"); do yes >/dev/null & done
sleep 3
e1=$(rdmsr -0 -x 0x611); t1=$(date +%s.%N)
V=""
for s in $(seq 1 12); do
  sleep 5
  raw=$(rdmsr -0 0x198)
  v=$(python3 -c "print(f'{((0x$raw>>32)&0xffff)/8192:.4f}')")
  V="$V $v"
done
e2=$(rdmsr -0 -x 0x611); t2=$(date +%s.%N)
fr=$(awk '{s+=$1;n++} END{printf "%.0f",s/n/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq)
tp=$(awk '{printf "%.0f",$1/1000}' /sys/class/hwmon/hwmon4/temp1_input 2>/dev/null)
pkill -9 yes 2>/dev/null; wait 2>/dev/null
python3 - "$label" "$V" "$e1" "$e2" "$t1" "$t2" "$ESU" "$fr" "$tp" <<'PY'
import sys
label=sys.argv[1]
vs=sorted(float(x) for x in sys.argv[2].split())
med=vs[len(vs)//2]
de=(int(sys.argv[4],16)-int(sys.argv[3],16))&0xffffffff
draw=de*(1.0/(2**int(sys.argv[7])))/(float(sys.argv[6])-float(sys.argv[5]))
print(f"[{label}] Vcore med={med*1000:.0f} mV (min {vs[0]*1000:.0f}/max {vs[-1]*1000:.0f}) "
      f"freq={sys.argv[8]}MHz draw={draw:.1f}W temp={sys.argv[9]}C")
# для машинного парсу:
print(f"RESULT,{label},{med*1000:.1f},{sys.argv[8]},{draw:.1f},{sys.argv[9]}")
PY
