import subprocess,sys,re,json
f=sys.argv[1]; x,y,w,h=[int(v) for v in sys.argv[2].split(',')]
# video: per-frame mean luma of the marker square (frames are sparse: VFR)
out=subprocess.run(['ffmpeg','-v','info','-i',f,'-map','0:v','-vf',f'crop={w}:{h}:{x}:{y},signalstats,metadata=print:key=lavfi.signalstats.YAVG','-f','null','-'],capture_output=True,text=True).stderr
ts=[float(m) for m in re.findall(r'pts_time:([\d.]+)',out)]; ys=[float(m) for m in re.findall(r'YAVG=([\d.]+)',out)]
flashes=[];prev=0
for t,yv in zip(ts,ys):
    if yv>150 and prev<=150: flashes.append(t)
    prev=yv
# audio: 5 ms RMS envelope, onset = first window above threshold after 0.5 s of quiet
sr=48000;win=240
raw=subprocess.run(['ffmpeg','-v','error','-i',f,'-map','0:a','-ac','1','-ar',str(sr),'-f','s16le','-'],capture_output=True).stdout
import array,math
a=array.array('h',raw)
env=[math.sqrt(sum(v*v for v in a[i:i+win])/win) for i in range(0,len(a)-win,win)]
peak=max(env) if env else 0; thr=peak*0.25
ticks=[];last=-9
for i,e in enumerate(env):
    t=i*win/sr
    if e>thr and t-last>1.0: ticks.append(t); last=t
pairs=[]
for fl in flashes:
    near=[tk for tk in ticks if abs(tk-fl)<1.0]
    if near: pairs.append((round(fl,3),round(min(near,key=lambda k:abs(k-fl)),3)))
print(json.dumps({'flashes':len(flashes),'ticks':len(ticks),'pairs':[(f,t,round((t-f)*1000)) for f,t in pairs]}))
