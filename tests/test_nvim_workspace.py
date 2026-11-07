import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('nvim_workspace',ROOT/'tools/nvim_workspace.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)

class WireTests(unittest.TestCase):
    def test_codec_and_partial_reads(self):
        left,right=__import__('socket').socketpair()
        rpc=bridge.Rpc.__new__(bridge.Rpc);rpc.sock=left;rpc.remaining=bridge.MAX_MESSAGE
        value={'unicode':'猫 café','values':[None,True,False,-50,2**35,{'x':'y'}]}
        try:
            right.sendall(bridge.pack(value));self.assertEqual(value,rpc.unpack())
        finally:left.close();right.close()
    def test_control_sequences_are_data(self):
        text=bridge.render(['hello\x1b[31m\x00\x9bworld'],3,80)
        self.assertNotIn('\x1b[31m',text);self.assertNotIn('\x00',text);self.assertNotIn('\x9b',text)
    def test_unicode_display_columns(self):
        self.assertEqual('猫',bridge.columns('猫猫',3))
        self.assertEqual('e\u0301',bridge.columns('e\u0301x',1))

    def test_unreachable_source_is_reported(self):
        data=bridge.inventory({'missing':'/nonexistent/nvim.sock'})
        self.assertEqual([],data['nodes']);self.assertEqual('missing',data['errors'][0]['source'])

class LiveNeovimTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        binary=os.environ.get('NVIM_TEST') or shutil.which('nvim')
        if not binary:
            candidate=Path.home()/'.local/nvim/bin/nvim'
            if candidate.exists():binary=str(candidate)
        if not binary:raise unittest.SkipTest('Neovim executable is unavailable')
        cls.directory=tempfile.TemporaryDirectory();cls.address=str(Path(cls.directory.name)/'nvim.sock')
        cls.process=subprocess.Popen([binary,'--headless','-u','NONE','-i','NONE','--listen',cls.address],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if Path(cls.address).exists():break
            if cls.process.poll() is not None:raise RuntimeError('Neovim fixture exited')
            time.sleep(.02)
        cls.rpc=bridge.Rpc(cls.address)
        cls.buffers=cls.rpc.lua('''
local result={}
for i=1,2 do
 vim.cmd('tabnew')
 local b=vim.api.nvim_get_current_buf()
 vim.fn.jobstart({'/bin/sh'}, {term=true})
 vim.t.spaceghost_name='Terminal '..i
 result[i]=b
end
return result
''')
        cls.rpc.lua("vim.b[...].spaceghost_attach='remote'",cls.buffers[0])
    @classmethod
    def tearDownClass(cls):
        try:cls.rpc.call('nvim_command','qa!')
        except (EOFError,OSError):pass
        cls.rpc.close()
        try:cls.process.wait(timeout=3)
        except subprocess.TimeoutExpired:cls.process.kill();cls.process.wait()
        cls.directory.cleanup()
    def test_inventory_stable_keys_and_nested_parent(self):
        sources={'home':self.address,'remote':self.address}
        data=bridge.inventory(sources,'fedora')
        self.assertFalse(data['errors'])
        terminals=[p for p in data['nodes'] if p['terminal']]
        self.assertEqual(4,len(terminals))
        keys=[p['key'] for p in data['nodes']]
        self.assertEqual(keys,[p['key'] for p in bridge.inventory(sources)['nodes']])
        parent=next(p['key'] for p in terminals if p['source']=='home' and p['remote']=='remote')
        self.assertTrue(all(p['parent']==parent for p in terminals if p['source']=='remote'))
    def test_input_targets_hidden_shell_without_switching_tabs(self):
        selected=self.rpc.lua('return vim.api.nvim_get_current_tabpage()')
        buffer=self.buffers[0]
        self.assertTrue(self.rpc.lua(bridge.SEND,buffer,"printf 'WORLD_INPUT_TARGET\\n'\n"))
        lines=[]
        for _ in range(50):
            lines=self.rpc.lua(bridge.FRAME,buffer,100)['lines']
            if any(line.strip()=='WORLD_INPUT_TARGET' for line in lines):break
            time.sleep(.03)
        self.assertTrue(any(line.strip()=='WORLD_INPUT_TARGET' for line in lines),lines)
        self.assertEqual(selected,self.rpc.lua('return vim.api.nvim_get_current_tabpage()'))
    def test_view_exit_does_not_stop_job(self):
        buffer=self.buffers[1]
        process=subprocess.run([os.sys.executable,str(ROOT/'tools/nvim_workspace.py'),'view','--socket',self.address,'--buffer',str(buffer)],input=b'',capture_output=True,timeout=5)
        self.assertEqual(0,process.returncode,process.stderr)
        frame=self.rpc.lua(bridge.FRAME,buffer,20)
        self.assertEqual(-1,self.rpc.lua('return vim.fn.jobwait({...},0)[1]',frame['job']))
    def test_closed_buffer_is_reported_without_new_jobs(self):
        self.assertEqual({'closed':True},self.rpc.lua(bridge.FRAME,999999,20))
    def test_editor_view_has_no_terminal_input(self):
        buffer=self.rpc.lua('return vim.api.nvim_create_buf(true,false)')
        self.assertFalse(self.rpc.lua(bridge.SEND,buffer,'must not enter the shared UI'))

if __name__=='__main__':unittest.main()
