#!/usr/bin/env python3
"""Expose existing Neovim panes to world terminals without owning their jobs.

Only stdlib is required. A source socket must already exist (including SSH
forwarded sockets); this tool never starts a server, shell, or SSH connection.
"""
import argparse
import codecs
import json
import os
from pathlib import Path
import select
import socket
import struct
import sys
import termios
import time
import tty
import unicodedata

MAX_MESSAGE = 8 * 1024 * 1024

def pack(value):
    if value is None: return b'\xc0'
    if value is True: return b'\xc3'
    if value is False: return b'\xc2'
    if isinstance(value, int):
        if 0 <= value < 128: return bytes([value])
        if -32 <= value < 0: return bytes([value & 255])
        return b'\xd3' + struct.pack('>q', value)
    if isinstance(value, str):
        data = value.encode('utf-8')
        return b'\xdb' + struct.pack('>I', len(data)) + data
    if isinstance(value, (list, tuple)):
        return b'\xdd' + struct.pack('>I', len(value)) + b''.join(map(pack, value))
    if isinstance(value, dict):
        return b'\xdf' + struct.pack('>I', len(value)) + b''.join(pack(k)+pack(v) for k,v in value.items())
    raise TypeError(type(value).__name__)

class Rpc:
    def __init__(self, address, timeout=3):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        try: self.sock.connect(str(address))
        except BaseException: self.sock.close(); raise
        self.sequence = 0
        self.remaining = MAX_MESSAGE
    def close(self): self.sock.close()
    def read(self, n):
        self.remaining -= n
        if n < 0 or self.remaining < 0: raise ValueError('Neovim response exceeds size limit')
        data = bytearray()
        while len(data) < n:
            block = self.sock.recv(n-len(data))
            if not block: raise EOFError('Neovim disconnected')
            data.extend(block)
        return bytes(data)
    def unpack(self, depth=0):
        if depth > 48: raise ValueError('Neovim response nesting limit')
        code = self.read(1)[0]
        if code < 128: return code
        if code >= 224: return code-256
        n = lambda size: int.from_bytes(self.read(size), 'big')
        if 160 <= code < 192: return self.read(code-160).decode('utf-8', 'replace')
        if code == 192: return None
        if code in (194,195): return code == 195
        if code in (202,203): return struct.unpack('>f' if code == 202 else '>d',self.read(4 if code==202 else 8))[0]
        if 204 <= code <= 207: return n(1 << (code-204))
        if 208 <= code <= 211: return int.from_bytes(self.read(1 << (code-208)), 'big', signed=True)
        if code in (196,197,198,217,218,219):
            length=n({196:1,197:2,198:4,217:1,218:2,219:4}[code]);data=self.read(length)
            return data if code < 200 else data.decode('utf-8','replace')
        if 144 <= code < 160: count=code-144;kind='array'
        elif 128 <= code < 144: count=code-128;kind='map'
        elif code in (220,221): count=n(2 if code==220 else 4);kind='array'
        elif code in (222,223): count=n(2 if code==222 else 4);kind='map'
        else: raise ValueError('Unsupported Neovim MessagePack type: '+str(code))
        if count > 100000: raise ValueError('Neovim collection exceeds size limit')
        if kind=='array': return [self.unpack(depth+1) for _ in range(count)]
        result={}
        for _ in range(count):
            key=self.unpack(depth+1);result[key]=self.unpack(depth+1)
        return result
    def call(self, method, *args):
        self.sequence += 1
        self.sock.sendall(pack([0,self.sequence,method,list(args)]))
        while True:
            self.remaining=MAX_MESSAGE
            response=self.unpack()
            if response[0]==1 and response[1]==self.sequence:
                if response[2] is not None: raise RuntimeError(str(response[2]))
                return response[3]
    def lua(self, code, *args): return self.call('nvim_exec_lua',code,list(args))

INVENTORY = r'''
local out={}
for index,tab in ipairs(vim.api.nvim_list_tabpages()) do
 local seen={}
 for _,win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
  local b=vim.api.nvim_win_get_buf(win)
  if not seen[b] and vim.api.nvim_win_get_config(win).relative=='' then
   seen[b]=true
   local kind=vim.bo[b].buftype
   if kind=='terminal' or kind=='' then
    local title=vim.t[tab].spaceghost_name or vim.b[b].term_title
    if not title or title=='' then title=vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b),':t') end
    if title=='' then title='Tab '..index end
    out[#out+1]={tab=tab,tabIndex=index,buffer=b,terminal=kind=='terminal',
      title=title,remote=vim.b[b].spaceghost_attach or vim.NIL,
      width=vim.api.nvim_win_get_width(win),height=vim.api.nvim_win_get_height(win)}
   end
  end
 end
end
return out
'''
FRAME = r'''
local b,rows=...;if not vim.api.nvim_buf_is_valid(b) then return {closed=true} end
local total=vim.api.nvim_buf_line_count(b)
local job=vim.b[b].terminal_job_id
return {lines=vim.api.nvim_buf_get_lines(b,math.max(0,total-rows),total,false),
  job=job or vim.NIL, terminal=vim.bo[b].buftype=='terminal'}
'''
SEND = r'''
local b,text=...;if not vim.api.nvim_buf_is_valid(b) or vim.bo[b].buftype~='terminal' then return false end
local job=vim.b[b].terminal_job_id;if not job then return false end
vim.api.nvim_chan_send(job,text);return true
'''

def plain(text):
    return ''.join(c if ord(c)>=32 and ord(c)!=127 and not 128<=ord(c)<160 else ' ' for c in str(text))

def inventory(sources, agent='local', executable=None):
    nodes=[];errors=[]
    for name,address in sources.items():
        rpc=None
        try:
            rpc=Rpc(address)
            for pane in rpc.lua(INVENTORY):
                key=f"{name}:{pane['tab']}:{pane['buffer']}"
                nodes.append(dict(pane,key=key,source=name,agent=agent,socket=str(address),
                    title=plain(pane['title'])[:160],command=[sys.executable,str(executable or Path(__file__).resolve()),'view','--socket',str(address),'--buffer',str(pane['buffer'])]))
        except (OSError,ValueError,EOFError,RuntimeError) as error:
            errors.append({'source':name,'error':str(error)})
        finally:
            if rpc: rpc.close()
    # A remote session is expanded only when its socket was explicitly supplied.
    # The first parent wins, and a later layout pass checks cycles.
    parents={}
    for node in nodes:
        remote=node.get('remote')
        if remote in sources and remote!=node['source']: parents.setdefault(remote,node['key'])
    for node in nodes: node['parent']=parents.get(node['source'])
    return {'version':1,'nodes':nodes,'errors':errors}

def columns(text, limit):
    out=[];width=0
    for char in text:
        cell=0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W','F') else 1
        if width+cell>limit:break
        out.append(char);width+=cell
    return ''.join(out)

def render(lines, rows, cols):
    # Buffer text is data, never terminal control sequences (files may contain ESC).
    clean=[columns(plain(line.expandtabs(8)),cols) for line in lines[-rows:]]
    return '\x1b[H'+'\r\n'.join(line+'\x1b[K' for line in clean)+'\x1b[J'

def view(address, buffer):
    rpc=Rpc(address);saved=None;previous=None
    decoder=codecs.getincrementaldecoder('utf-8')('replace')
    try:
        if sys.stdin.isatty(): saved=termios.tcgetattr(0);tty.setraw(0)
        sys.stdout.write('\x1b[?1049h\x1b[?25l');sys.stdout.flush()
        while True:
            size=__import__('shutil').get_terminal_size((100,28));rows=max(1,min(size.lines-1,100));cols=max(1,min(size.columns,300))
            frame=rpc.lua(FRAME,buffer,rows)
            if frame.get('closed'): break
            footer='LIVE SHELL · close this view to detach' if frame.get('terminal') else 'READ ONLY · Neovim editor buffer'
            output=render(frame['lines'],rows,cols)+f'\x1b[{rows+1};1H\x1b[2K'+columns(footer,cols)
            if output!=previous:
                sys.stdout.write(output);sys.stdout.flush();previous=output
            ready,_,_=select.select([sys.stdin],[],[],0.15)
            if ready:
                data=os.read(0,4096)
                if not data: break
                text=decoder.decode(data)
                if text and frame.get('terminal'): rpc.lua(SEND,buffer,text)
    finally:
        rpc.close()
        if saved is not None: termios.tcsetattr(0,termios.TCSADRAIN,saved)
        sys.stdout.write('\x1b[?25h\x1b[?1049l');sys.stdout.flush()

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
    listing=sub.add_parser('snapshot');listing.add_argument('--source',action='append',required=True,metavar='NAME=SOCKET');listing.add_argument('--agent',default='local');listing.add_argument('--output',type=Path);listing.add_argument('--viewer',type=Path)
    terminal=sub.add_parser('view');terminal.add_argument('--socket',required=True);terminal.add_argument('--buffer',required=True,type=int)
    args=parser.parse_args()
    if args.action=='view': view(args.socket,args.buffer);return
    sources={}
    for item in args.source:
        name,sep,address=item.partition('=')
        if not sep or not name or not address: parser.error('--source must be NAME=SOCKET')
        if name in sources: parser.error('duplicate source name')
        sources[name]=address
    result=inventory(sources,args.agent,args.viewer);data=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        temporary=args.output.with_name(args.output.name+'.tmp');temporary.write_text(data);os.replace(temporary,args.output)
    else: sys.stdout.write(data)
    if not result['nodes'] and result['errors']: raise SystemExit(1)
if __name__=='__main__': main()
