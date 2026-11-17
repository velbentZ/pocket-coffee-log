import struct,time,json,socket
import usb.core,usb.util
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
r={'rndis':[]}
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

except Exception as e:r['rndis'].append({'error':str(e)})
finally:usb.util.dispose_resources(D)
print(json.dumps(r,indent=2))
