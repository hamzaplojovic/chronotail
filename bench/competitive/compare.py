#!/usr/bin/env python3
import csv,sys
from pathlib import Path
old_path,new_path,out_path=map(Path,sys.argv[1:4])
old={(r['workload'],r['engine']):r for r in csv.DictReader(old_path.open())}
new={(r['workload'],r['engine']):r for r in csv.DictReader(new_path.open())}
fields=['workload','before_ops_per_sec','after_ops_per_sec','speedup','before_p50_us','after_p50_us','before_p99_us','after_p99_us','before_file_bytes','after_file_bytes']
with out_path.open('w',newline='') as f:
 w=csv.DictWriter(f,fields);w.writeheader()
 for workload,engine in sorted(k for k in old if k[1]=='chronotail'):
  a,b=old[workload,engine],new[workload,engine]
  w.writerow({'workload':workload,'before_ops_per_sec':a['operations_per_sec'],'after_ops_per_sec':b['operations_per_sec'],'speedup':float(b['operations_per_sec'])/float(a['operations_per_sec']),'before_p50_us':a['p50_us'],'after_p50_us':b['p50_us'],'before_p99_us':a['p99_us'],'after_p99_us':b['p99_us'],'before_file_bytes':a['file_bytes'],'after_file_bytes':b['file_bytes']})
