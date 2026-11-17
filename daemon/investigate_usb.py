import usb.core,usb.util,socket,concurrent.futures,json,sys
sys.path.insert(0,'.')
from core.camera_sta_bridge import build_duml_packet
D=usb.core.find(idVendor=0x2ca3,idProduct=0x20)
r={'interfaces':[],'queries':[]}
for i in D.get_active_configuration():
 r['interfaces'].append({'number':i.bInterfaceNumber,'alt':i.bAlternateSetting,'class':i.bInterfaceClass,'subclass':i.bInterfaceSubClass})
 if i.bAlternateSetting:continue
 try:
  usb.util.claim_interface(D,i.bInterfaceNumber)
  if i.bInterfaceClass==8:
   r['queries'].append({'interface':i.bInterfaceNumber,'max_lun':list(D.ctrl_transfer(0xa1,0xfe,0,i.bInterfaceNumber,1,timeout=300))})
  elif i.bInterfaceNumber==4:
   for t,x in [(7,0),(8,0),(8,2),(1,0)]:
    for cs,cid in [(0,0),(0,1),(7,7),(7,0x30),(7,0x44),(7,0x47)]:
     q={'receiver':[t,x],'set':cs,'id':cid}
     try:
      D.write(4,build_duml_packet(2,0,t,x,cs,cid),timeout=200)
      q['raw_rx']=bytes(D.read(0x85,4096,timeout=200)).hex()
     except Exception as e:q['error']=str(e)
     r['queries'].append(q)
  usb.util.release_interface(D,i.bInterfaceNumber)
 except Exception as e:r['queries'].append({'interface':i.bInterfaceNumber,'error':str(e)})
def check(z):
 h,p=z
 try:
  with socket.create_connection((h,p),.3) as s:
   s.settimeout(.2)
   try:b=s.recv(256).decode(errors='replace')
   except Exception:b=''
   return {'host':h,'port':p,'open':True,'banner':b}
 except OSError as e:return {'host':h,'port':p,'open':False,'error':str(e)}
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:r['tcp']=list(ex.map(check,[(h,p) for h in ['192.168.42.2','192.168.2.1'] for p in [21,23,80,5555,9004,8088,554]]))
print(json.dumps(r,indent=2))
