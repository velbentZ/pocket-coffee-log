import sys,json,struct,time
sys.path.insert(0,'.')
import usb.core,usb.util
from core.camera_sta_bridge import build_duml_packet,crc16_dji
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
r={'layout':[], 'duml':[], 'rndis':[]}
try:
 usb.util.claim_interface(D,0);usb.util.claim_interface(D,1)
 def control(msg):
  D.ctrl_transfer(0x21,0,0,0,msg,timeout=1000)
  return bytes(D.ctrl_transfer(0xa1,1,0,0,4096,timeout=1000))
 init=control(struct.pack('<6I',2,24,1,1,0,16384));r['rndis'].append({'initialize':init.hex()})
 setfilter=control(struct.pack('<7I',5,32,2,0x1010e,4,20,0)+struct.pack('<I',15));r['rndis'].append({'filter':setfilter.hex()})
 it=D.get_active_configuration()[(1,0)];out=next(e.bEndpointAddress for e in it if not e.bEndpointAddress&128);inp=next(e.bEndpointAddress for e in it if e.bEndpointAddress&128)
 import socket
 peer_mac=None
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
  if target=='192.168.42.2':
   for raw in row['received']:
    b=bytes.fromhex(raw);off=int.from_bytes(b[8:12],'little')+8;f=b[off:]
    if f[12:14]==b'\x08\x06' and f[28:32]==socket.inet_aton(target):peer_mac=f[22:28]
 if peer_mac is None:raise RuntimeError('No camera ARP reply')
 def checksum(b):
  if len(b)%2:b+=b'\0'
  v=sum(struct.unpack('!%dH'%(len(b)//2),b));v=(v&65535)+(v>>16);v=(v&65535)+(v>>16);return (~v)&65535
 src=socket.inet_aton('192.168.42.1');dst=socket.inet_aton('192.168.42.2')
 for port in sorted(set(range(1,1025)) | set(range(5555,5586)) | set(range(8000,9011)) | {1080,1433,1521,1883,2049,2375,3000,3306,3389,5000,5037,5432,5900,6379,7000,7878,9090,9200,9999,10000,11211,20000,22345,27017,32768,49152,50000,55555,60000,65535}):
  tcp=struct.pack('!HHIIBBHHH',40000,port,100,0,80,2,8192,0,0)
  chk=checksum(src+dst+struct.pack('!BBH',0,6,20)+tcp);tcp=tcp[:16]+struct.pack('!H',chk)+tcp[18:]
  ip=struct.pack('!BBHHHBBH',69,0,40,port,0,64,6,0)+src+dst;ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
  frame=peer_mac+bytes.fromhex('0200000000840800')+ip+tcp
  row={'tcp_syn_port':port,'received':[]};r['rndis'].append(row)
  D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
  end=time.monotonic()+0.04
  while time.monotonic()<end:
   try:row['received'].append(bytes(D.read(inp,16384,timeout=10)).hex())
   except usb.core.USBError:pass
except Exception as e:r['rndis'].append({'error':str(e)})
finally:usb.util.dispose_resources(D)
print(json.dumps(r,indent=2))
