import json,struct
from pathlib import Path
root=Path(__file__).parent
r=json.loads((root/'port-discovery.json').read_text());ports=set();flags={}
for row in r['rndis']:
 if 'tcp_syn_port' in row:ports.add(row['tcp_syn_port'])
 for raw in row.get('received',[]):
  b=bytes.fromhex(raw)
  while len(b)>=44:
   typ,n,off,size=struct.unpack('<4I',b[:16]);f=b[8+off:8+off+size];b=b[n:] if n else b''
   if typ!=1 or len(f)<54 or f[12:14]!=b'\x08\x00':continue
   ip=f[14:];h=(ip[0]&15)*4
   if ip[9]!=6 or ip[12:16]!=bytes([192,168,42,2]):continue
   tcp=ip[h:]
   if len(tcp)<20 or int.from_bytes(tcp[2:4],'big')!=40000:continue
   p=int.from_bytes(tcp[:2],'big');flags.setdefault(p,set()).add(tcp[13])
s={'ports_probed':len(ports),'open_syn_ack':sorted(p for p,v in flags.items() if any(x&18==18 for x in v)),'reset_ports':sorted(p for p,v in flags.items() if any(x&4 for x in v)),'no_observed_response':sorted(ports-flags.keys())}
(root/'port-discovery-summary.json').write_text(json.dumps(s,indent=2)+'\n')
print({k:len(v) if k in ['reset_ports','no_observed_response'] else v for k,v in s.items()})
