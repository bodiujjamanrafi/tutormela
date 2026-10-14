"""Build lightweight SVG paths from the attributed geoBoundaries ADM2 dataset."""
import json, math, heapq, re, urllib.request
from pathlib import Path
root=Path(__file__).resolve().parents[1]
data=json.loads((root/'src/assets/maps/bangladesh-districts.geojson').read_text())
alias={'Brahamanbaria':'Brahmanbaria','Barisal':'Barishal','Bogra':'Bogura','Chittagong':'Chattogram','Comilla':'Cumilla','Jessore':'Jashore','Nawabganj':'Chapainawabganj',"Cox's Bazar":'Cox’s Bazar','Maulvibazar':'Moulvibazar','Jhalokati':'Jhalokati','Jhalokathi':'Jhalokati','Netrakona':'Netrokona'}
def project(p):return [math.radians(p[0]),-math.log(math.tan(math.pi/4+math.radians(p[1])/2))]
allpoints=[project(p) for f in data['features'] for poly in (f['geometry']['coordinates'] if f['geometry']['type']=='MultiPolygon' else [f['geometry']['coordinates']]) for ring in poly for p in ring]
minx,miny=map(min,zip(*allpoints));maxx,maxy=map(max,zip(*allpoints));scale=min(480/(maxx-minx),570/(maxy-miny));xoff=(640-(maxx-minx)*scale)/2;yoff=(650-(maxy-miny)*scale)/2-10

def screen(p):x,y=project(p);return [(x-minx)*scale+xoff,(y-miny)*scale+yoff]
def distseg(p,a,b):x,y=p;dx,dy=b[0]-a[0],b[1]-a[1];t=max(0,min(1,((x-a[0])*dx+(y-a[1])*dy)/(dx*dx+dy*dy))) if dx or dy else 0;return (x-a[0]-t*dx)**2+(y-a[1]-t*dy)**2

def simplify(points,eps=.45):
 if len(points)<4:return points
 best=0;idx=0
 for i in range(1,len(points)-1):
  d=distseg(points[i],points[0],points[-1])
  if d>best:best=d;idx=i
 if best>eps*eps:return simplify(points[:idx+1],eps)[:-1]+simplify(points[idx:],eps)
 return [points[0],points[-1]]
def area(r):return abs(sum(r[i][0]*r[i+1][1]-r[i+1][0]*r[i][1] for i in range(len(r)-1))/2)
def distance(x,y,rings):
 inside=False;best=float('inf')
 for ring in rings:
  j=len(ring)-1
  for i in range(len(ring)):
   a,b=ring[i],ring[j]
   if (a[1]>y)!=(b[1]>y) and x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]:inside=not inside
   best=min(best,distseg([x,y],a,b));j=i
 return math.sqrt(best)*(1 if inside else -1)
def labelpoint(rings):
 xs,ys=zip(*rings[0]);lo,hi=min(xs),max(xs);top,bottom=min(ys),max(ys);size=min(hi-lo,bottom-top);h=size/2
 best=((lo+hi)/2,(top+bottom)/2);bd=distance(*best,rings);queue=[];counter=0
 def push(x,y,h):
  nonlocal counter
  d=distance(x,y,rings);counter+=1;heapq.heappush(queue,(-(d+h*math.sqrt(2)),counter,x,y,h,d))
 x=lo
 while x<hi:
  y=top
  while y<bottom:push(x+h,y+h,h);y+=size
  x+=size
 while queue:
  neg,_,x,y,h,d=heapq.heappop(queue)
  if d>bd:best=(x,y);bd=d
  if -neg-bd<=.6:continue
  h/=2
  for dx,dy in [(-h,-h),(h,-h),(-h,h),(h,h)]:push(x+dx,y+dy,h)
 return list(best)
features=[]
for i,f in enumerate(data['features']):
 name=alias.get(f['properties']['shapeName'],f['properties']['shapeName']);polys=f['geometry']['coordinates'] if f['geometry']['type']=='MultiPolygon' else [f['geometry']['coordinates']];polys=[[simplify([screen(p) for p in ring]) for ring in poly] for poly in polys];polys=[p for p in polys if len(p[0])>3 and area(p[0])>.15]
 largest=max(polys,key=lambda p:area(p[0]));xy=labelpoint(largest)
 path=''.join('M'+'L'.join(f'{x:.1f},{y:.1f}' for x,y in ring)+'Z' for poly in polys for ring in poly)
 features.append({'name':name,'path':path,'center':[round(v,1) for v in xy],'color':i%8})
# Interior anchors only. Runtime font fitting and clipping keep the whole label in its district.
for f in features:f['label']=f['center'][:]
(root/'src/assets/maps/district-paths.json').write_text(json.dumps(features,separators=(',',':')))
print(f'Built {len(features)} district paths, {(root/"src/assets/maps/district-paths.json").stat().st_size:,} bytes')
# Store fonts locally; the browser never contacts Google Fonts.
css=(root/'src/assets/maps/font-download.css').read_text()
for name,weight in [('Public Sans','400'),('Public Sans','600'),('Source Serif 4','400'),('Source Serif 4','500')]:
 blocks=re.findall(r'@font-face\s*\{([^}]+)\}',css)
 for block in blocks:
  if f"font-family: '{name}'" in block and f'font-weight: {weight}' in block:
   url=re.search(r'url\(([^)]+)\)',block).group(1);dest=root/'public/fonts'/f'{name.lower().replace(" ","-")}-{weight}.ttf';
   if not dest.exists():urllib.request.urlretrieve(url,dest)
   print(dest.name,dest.stat().st_size);break
