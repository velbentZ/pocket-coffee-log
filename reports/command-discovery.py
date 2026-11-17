"""Explicitly authorized live experiment; unknown commands can change device state."""
import sys,json,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import usb.core,usb.util
from core.camera_sta_bridge import build_duml_packet,crc8_dji,crc16_dji
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
seq=18000
path=Path(__file__).with_name('command-discovery.jsonl')
def query(target,cs,ci,payload=b''):
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
 return row
try:
 usb.util.claim_interface(D,4)
 mismatch=[]
 for target,cs in [((7,0),7),((8,0),7),((8,2),7),((8,0),0),((8,2),0),((8,0),8),((8,2),8)]:
  for ci in range(256):
   r=query(target,cs,ci)
   if target==(7,0) and cs==7 and any(p['first_byte']==228 for p in r['responses']):mismatch.append(ci)
  print('finished',target,cs,flush=True)
 for ci in mismatch:
  for length in range(1,161):query((7,0),7,ci,bytes(length))
  print('lengths finished',ci,flush=True)
finally:usb.util.dispose_resources(D)
