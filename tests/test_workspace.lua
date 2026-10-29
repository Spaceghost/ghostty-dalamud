package.path='lua/?.lua;'..package.path
local workspace=require('workspace')
local function node(key,source,tab,parent)
 return {key=key,source=source,tab=tab,parent=parent,title='shell '..key,agent='local',command={'python3','view',key}}
end
local nodes={node('root','home',1),node('child','remote',1,'root'),node('grandchild','nested',2,'child'),node('other','home',2)}
local a=workspace.layout(nodes)
assert(a.root.group==a.child.group and a.root.colour==a.grandchild.colour)
assert(a.grandchild.depth==2 and a.child.depth==1 and a.root.depth==0)
assert(a.root.group~=a.other.group)
local reversed={nodes[4],nodes[3],nodes[2],nodes[1]};local b=workspace.layout(reversed)
for key,p in pairs(a) do
 assert(p.x==b[key].x and p.y==b[key].y and p.z==b[key].z and p.colour==b[key].colour)
 assert(p.label:find(' / ',1,true) and p.pixels_per_yalm>0)
end
assert(not pcall(workspace.layout,{node('a','a',1,'b'),node('b','b',1,'a')}))
assert(not pcall(workspace.layout,{node('a','a',1),node('a','b',1)}))
assert(not pcall(workspace.layout,{node('bad\nkey','a',1)}))
local orphan=workspace.layout({node('a','a',1,'missing')});assert(orphan.a.depth==0)
local many={}
for i=1,256 do many[i]=node('n'..i,'host'..(i%12),i%4) end
local large=workspace.layout(many)
for key,p in pairs(large) do
 assert(p.x==p.x and p.z==p.z)
 for key2,q in pairs(large) do
  if key~=key2 then
   assert((p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2>1, 'distinct panes overlap')
  end
 end
end
local opened,all={},{}
ghostty={player=function() return {x=0,y=0,z=0,rotation=0} end,
 panels=function() return all end,
 terminal_new=function(opts) local id=#opened+1;opened[id]=opts;all[#all+1]={id=id,profile=opts.profile};return id end}
local config={profiles={},world={anchors={},place=function() return {x=0,y=0,z=0} end}}
assert(workspace.configure(config,{version=1,nodes=nodes}))
assert(#config.profiles==4)
for i=1,5 do workspace.tick(i) end
assert(#opened==4)
workspace.tick(6);assert(#opened==4,'reconcile must not duplicate views')
local label,colour=workspace.nameplate(1);assert(label and colour)
local key=workspace.panels[1];config.world.anchors[1]={kind='pet'}
local p=config.world.place(1,1,false,false);assert(p.x==a[key].x and p.z==a[key].z)
config.world.anchors[1]={kind='at'};assert(config.world.place(1,2,false,false).x==0,'manual pins are preserved')
local removed=table.remove(all,1);workspace.tick(7);assert(#opened==4,'closing a panel must keep it closed');assert(workspace.panels[removed.id]==nil,'closed panel metadata is retired')
local unicode=workspace.layout({{key='unicode',source='host',tab=1,title=string.rep('猫',160)}})
assert(utf8.len(unicode.unicode.label) and #unicode.unicode.label<=480, 'nameplates retain valid bounded Unicode')
local before=#config.profiles
assert(not workspace.configure(config,{version=1,nodes={{key='invalid',source='a',tab=1,command={'bad\0command'}}}}))
assert(#config.profiles==before,'bad input must not partially apply')
print('workspace: hierarchy, colours, deterministic spread, cycles, 256 panes, lifecycle, pins, validation OK')
