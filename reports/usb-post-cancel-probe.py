import sys,json,struct,time
sys.path.insert(0,'.')
import usb.core,usb.util
from core.camera_sta_bridge import build_duml_packet,crc16_dji
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
r={'layout':[], 'duml':[], 'rndis':[]}
for i in D.get_active_configuration():
 r['layout'].append({'interface':i.bInterfaceNumber,'class':i.bInterfaceClass,'subclass':i.bInterfaceSubClass,'protocol':i.bInterfaceProtocol,'endpoints':[e.bEndpointAddress for e in i]})
usb.util.claim_interface(D,4)
seq=12000
for target in [(8,0),(8,2),(1,0),(7,0)]:
 for cs,ci in [(0,1),(7,7)]:
  seq+=1; row={'target':target,'cmd_set':cs,'cmd_id':ci,'seq':seq,'responses':[]};r['duml'].append(row)
  try:
   row['written']=D.write(4,build_duml_packet(10,1,*target,cs,ci,seq=seq),timeout=500)
   end=time.monotonic()+1
   while time.monotonic()<end:
    try:
     b=bytes(D.read(0x85,4096,timeout=100))
     while len(b)>=13 and b[0]==85:
      n=int.from_bytes(b[1:3],'little')&1023;f=b[:n];b=b[n:]
      if len(f)<13:break
      if int.from_bytes(f[6:8],'little')==seq and f[4]==(target[0]|target[1]<<5):
       row['responses'].append({'hex':f.hex(),'crc_valid':crc16_dji(f[:-2])==int.from_bytes(f[-2:],'little')})
    except usb.core.USBError:pass
  except Exception as e:row['error']=str(e)
usb.util.release_interface(D,4)
try:
 usb.util.claim_interface(D,0);usb.util.claim_interface(D,1)
 def control(msg):
  D.ctrl_transfer(0x21,0,0,0,msg,timeout=1000)
  return bytes(D.ctrl_transfer(0xa1,1,0,0,4096,timeout=1000))
 init=control(struct.pack('<6I',2,24,1,1,0,16384));r['rndis'].append({'initialize':init.hex()})
 setfilter=control(struct.pack('<7I',5,32,2,0x1010e,4,20,0)+struct.pack('<I',15));r['rndis'].append({'filter':setfilter.hex()})
 it=D.get_active_configuration()[(1,0)];out=next(e.bEndpointAddress for e in it if not e.bEndpointAddress&128);inp=next(e.bEndpointAddress for e in it if e.bEndpointAddress&128)
 import socket
 for target,source in [('192.168.42.2','192.168.42.1'),('192.168.2.1','192.168.2.2')]:
  mac=bytes.fromhex('020000000084');frame=b'\xff'*6+mac+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,1)+mac+socket.inet_aton(source)+b'\0'*6+socket.inet_aton(target)
  row={'arp_target':target,'received':[]};r['rndis'].append(row)
  try:
   row['written']=D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
   end=time.monotonic()+3
   while time.monotonic()<end:
    try:row['received'].append(bytes(D.read(inp,16384,timeout=300)).hex())
    except usb.core.USBError:pass
  except Exception as e:row['error']=str(e)
 def checksum(b):
  if len(b)%2:b+=b'\0'
  v=sum(struct.unpack('!%dH'%(len(b)//2),b));v=(v&65535)+(v>>16);v=(v&65535)+(v>>16);return (~v)&65535
 src=socket.inet_aton('192.168.42.1');dst=socket.inet_aton('192.168.42.2')
 for port in [21,22,23,80,443,554,5555,7878,9004,22345]:
  tcp=struct.pack('!HHIIBBHHH',40000,port,100,0,80,2,8192,0,0)
  chk=checksum(src+dst+struct.pack('!BBH',0,6,20)+tcp);tcp=tcp[:16]+struct.pack('!H',chk)+tcp[18:]
  ip=struct.pack('!BBHHHBBH',69,0,40,port,0,64,6,0)+src+dst;ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
  frame=bytes.fromhex('56d6c1165fed0200000000840800')+ip+tcp
  row={'tcp_syn_port':port,'received':[]};r['rndis'].append(row)
  D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
  end=time.monotonic()+0.5
  while time.monotonic()<end:
   try:row['received'].append(bytes(D.read(inp,16384,timeout=100)).hex())
   except usb.core.USBError:pass
except Exception as e:r['rndis'].append({'error':str(e)})
finally:usb.util.dispose_resources(D)
print(json.dumps(r,indent=2))
