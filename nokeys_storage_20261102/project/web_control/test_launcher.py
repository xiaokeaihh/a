import unittest,sys,socket
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import start_web
sys.path.insert(0,str(start_web.ROOT/'stabilization_tools'))
import server

class LauncherTests(unittest.TestCase):
    def test_reuse_does_not_create_second_serial_owner(self):
        existing=dict(app_id='wyc-unified-control',project_root=str(start_web.ROOT),control_version=server.CONTROL_VERSION)
        with patch.object(start_web,'existing_service',return_value=existing),patch.object(start_web,'open_supported_browser') as opened,patch.object(server,'main') as serve:
            start_web.main([])
            opened.assert_called_once_with('http://localhost:8770/')
            serve.assert_not_called()

    def test_busy_old_or_other_project_service_is_not_replaced(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));sock.listen(1);port=sock.getsockname()[1]
            existing=dict(app_id='wyc-unified-control',project_root='another project',control_version=server.CONTROL_VERSION)
            with patch.object(start_web,'existing_service',return_value=existing),patch.object(server,'main') as serve:
                with self.assertRaises(SystemExit):start_web.main(['--port',str(port),'--no-browser'])
                serve.assert_not_called()

if __name__=='__main__':unittest.main()
