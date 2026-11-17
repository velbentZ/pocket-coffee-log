import sys,json,struct,time
sys.path.insert(0,'.')
import usb.core,usb.util
from core.camera_sta_bridge import build_duml_packet,crc16_dji
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
r={'source_ip':'192.168.2.2','destination_ip':'192.168.2.1','timestamp':time.time(),'rndis':[]}
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
 for target,source in [('192.168.2.1','192.168.2.2')]:
  mac=bytes.fromhex('020000000084');frame=b'\xff'*6+mac+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,1)+mac+socket.inet_aton(source)+b'\0'*6+socket.inet_aton(target)
  row={'arp_target':target,'received':[]};r['rndis'].append(row)
  try:
   row['written']=D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
   end=time.monotonic()+3
   while time.monotonic()<end:
    try:row['received'].append(bytes(D.read(inp,16384,timeout=300)).hex())
    except usb.core.USBError:pass
  except Exception as e:row['error']=str(e)
  if target=='192.168.2.1':
   for raw in row['received']:
    b=bytes.fromhex(raw);off=int.from_bytes(b[8:12],'little')+8;f=b[off:]
    if f[12:14]==b'\x08\x06' and f[28:32]==socket.inet_aton(target):peer_mac=f[22:28]
 if peer_mac is None:raise RuntimeError('No camera ARP reply')
 def checksum(b):
  if len(b)%2:b+=b'\0'
  v=sum(struct.unpack('!%dH'%(len(b)//2),b));v=(v&65535)+(v>>16);v=(v&65535)+(v>>16);return (~v)&65535
 src=socket.inet_aton('192.168.2.2');dst=socket.inet_aton('192.168.2.1')
 for port in (21,22,23,80,443,554,5037,5555,7878,8080,8088,9004,22345):
  tcp=struct.pack('!HHIIBBHHH',40000,port,100,0,80,2,8192,0,0)
  chk=checksum(src+dst+struct.pack('!BBH',0,6,20)+tcp);tcp=tcp[:16]+struct.pack('!H',chk)+tcp[18:]
  ip=struct.pack('!BBHHHBBH',69,0,40,port,0,64,6,0)+src+dst;ip=ip[:10]+struct.pack('!H',checksum(ip))+ip[12:]
  frame=peer_mac+bytes.fromhex('0200000000840800')+ip+tcp
  row={'tcp_syn_port':port,'received':[]};r['rndis'].append(row)
  D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
  end=time.monotonic()+0.3
  while time.monotonic()<end:
   try:row['received'].append(bytes(D.read(inp,16384,timeout=10)).hex())
   except usb.core.USBError:pass
 # Sweep using the same valid source address as the successful ARP control.
 row={'arp_sweep':'192.168.5.1-254','source':'192.168.2.2','sent':[],'received':[]};r['rndis'].append(row)
 for host in range(1,255):
  target='192.168.5.'+str(host)
  frame=b'\xff'*6+mac+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,1)+mac+socket.inet_aton('192.168.2.2')+b'\0'*6+socket.inet_aton(target)
  D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
  row['sent'].append(target)
  try:row['received'].append(bytes(D.read(inp,16384,timeout=20)).hex())
  except usb.core.USBTimeoutError:pass
 end=time.monotonic()+2
 while time.monotonic()<end:
  try:row['received'].append(bytes(D.read(inp,16384,timeout=100)).hex())
  except usb.core.USBTimeoutError:pass
 row={'arp_health_after':'192.168.2.1','received':[]};r['rndis'].append(row)
 frame=b'\xff'*6+mac+b'\x08\x06'+struct.pack('!HHBBH',1,0x800,6,4,1)+mac+socket.inet_aton('192.168.2.2')+b'\0'*6+socket.inet_aton('192.168.2.1')
 D.write(out,struct.pack('<11I',1,44+len(frame),36,len(frame),0,0,0,0,0,0,0)+frame,timeout=1000)
 end=time.monotonic()+1
 while time.monotonic()<end:
  try:row['received'].append(bytes(D.read(inp,16384,timeout=100)).hex())
  except usb.core.USBTimeoutError:pass
except Exception as e:r['rndis'].append({'error':str(e)})
finally:usb.util.dispose_resources(D)
print(json.dumps(r,indent=2))
