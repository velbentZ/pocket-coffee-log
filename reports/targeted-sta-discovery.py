"""Explicitly authorized live experiment; unknown commands can change device state."""
import sys,json,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import usb.core,usb.util
from core.camera_sta_bridge import build_duml_packet,crc8_dji,crc16_dji
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
seq=41000
path=Path(__file__).with_name('targeted-sta-discovery.jsonl')
def query(target,cs,ci,payload=b''):
 assert target == (7,0) and cs == 7 and ci not in (8,13,15)
 global seq
 seq+=1
 row=dict(target=target,cmd_set=cs,cmd_id=ci,length=len(payload),seq=seq,responses=[])
 buf=b''
 try:
  D.write(4,build_duml_packet(10,1,*target,cs,ci,payload,seq=seq),timeout=500)
  end=time.monotonic()+.25
  while time.monotonic()<end:
   try:buf+=bytes(D.read(0x85,4096,timeout=50))
   except usb.core.USBTimeoutError:continue
   while len(buf)>=4:
    if buf[0]!=85 or crc8_dji(buf[:3])!=buf[3]:buf=buf[1:];continue
    n=int.from_bytes(buf[1:3],'little')&1023
    if n<13:buf=buf[1:];continue
    if len(buf)<n:break
    f,buf=buf[:n],buf[n:]
    if (int.from_bytes(f[6:8],'little')==seq and f[4]==target[0]|target[1]<<5 and f[5]==42 and f[8]&128 and f[9:11]==bytes([cs,ci]) and crc16_dji(f[:-2])==int.from_bytes(f[-2:],'little')):
     p=f[11:-2];row['responses'].append({'payload':p.hex() if not(cs==7 and ci==14) else '[credential redacted]','first_byte':p[0] if p else None});end=time.monotonic()
 except usb.core.USBError as e:row['error']=str(e)
 with path.open('a') as out:out.write(json.dumps(row)+'\n')
 if row.get('error'): raise RuntimeError(row['error'])
 return row

def checked(ci,p=b'',label='empty'):
 r=query((7,0),7,ci,p)
 if not r['responses']:
  health=query((7,0),7,12)
  if not health['responses']:
   for attempt in range(20):
    time.sleep(1)
    health=query((7,0),7,12)
    if health['responses']:break
   else:raise RuntimeError('Wi-Fi unavailable; stopping rather than recording invalid probes')
   r=query((7,0),7,ci,p)
 return r
try:
 usb.util.claim_interface(D,4)
 if not checked(12)['responses']: raise RuntimeError('No live MAC response')
 candidates=[70]
 for ci in [*range(17,56),178,182]:
  r=checked(ci)
  print(ci,r['responses'],flush=True)
  if any(x['first_byte'] in (227,228) for x in r['responses']):candidates.append(ci)
 for ci in candidates:
  for n in range(1,161): checked(ci,bytes(n))
  print('raw complete',ci,flush=True)
  s=b'probe';p=b'probe12345'
  patterns=[bytes([len(s)])+s,bytes([len(s),len(p)])+s+p,s+b'\0'+p+b'\0',s.ljust(32,b'\0')+p.ljust(64,b'\0')]
  for flag in (0,1,2):
   patterns += [bytes([flag,len(s)])+s,bytes([flag,len(s)])+s+bytes([len(p)])+p]
   for uid in (0,1,255):patterns.append(bytes([uid,flag,len(s)])+s+bytes([len(p)])+p)
  for width in (32,64):patterns.append(bytes([len(s)])+s.ljust(32,b'\0')+bytes([len(p)])+p.ljust(width,b'\0'))
  for payload in patterns:checked(ci,payload)
  print('patterns complete',ci,flush=True)
 for ci in (72,74,75,77,68,174):checked(ci)
finally:usb.util.dispose_resources(D)
