"""One local page and one serial owner for view control, capture and stabilization."""
from pathlib import Path
import argparse,json,os,socket,sys,urllib.request,webbrowser
ROOT=Path(__file__).resolve().parents[1]

def open_supported_browser(url):
    for root,tail in [('ProgramFiles(x86)','Microsoft/Edge/Application/msedge.exe'),
                      ('ProgramFiles','Microsoft/Edge/Application/msedge.exe'),
                      ('ProgramFiles','Google/Chrome/Application/chrome.exe'),
                      ('LOCALAPPDATA','Google/Chrome/Application/chrome.exe')]:
        binary=Path(os.environ.get(root,''))/tail
        if binary.is_file():return webbrowser.BackgroundBrowser(str(binary)).open(url)
    return webbrowser.open(url)

def existing_service(port):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/status',timeout=1) as response:
            return json.load(response)
    except (OSError,ValueError):return None

def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--port',type=int,default=None)
    parser.add_argument('--no-browser',action='store_true')
    args=parser.parse_args(argv)
    sys.path.insert(0,str(ROOT/'stabilization_tools'))
    try:
        from server import CONTROL_VERSION,main as serve
    except ImportError as error:
        raise SystemExit('当前 Python 缺少稳像依赖，请使用已安装 numpy、pyserial 的 Python。'+str(error))
    # A different project must never be mistaken for this copied project.
    if args.port is None:
        free_port=None
        for candidate in range(8770,8791):
            current=existing_service(candidate)
            if current and current.get('project_root')==str(ROOT) and current.get('control_version')==CONTROL_VERSION:
                args.port=candidate;break
            with socket.socket() as probe:
                probe.settimeout(.15)
                if free_port is None and probe.connect_ex(('127.0.0.1',candidate))!=0:free_port=candidate
        if args.port is None:args.port=free_port
        if args.port is None:raise SystemExit('8770～8790端口均已占用，请关闭不用的网页控制服务')
    current=existing_service(args.port)
    if current and current.get('app_id')=='wyc-unified-control' and current.get('project_root')==str(ROOT) and current.get('control_version')==CONTROL_VERSION:
        print(f'统一控制网页已运行：http://localhost:{args.port}/',flush=True)
        if not args.no_browser:open_supported_browser(f'http://localhost:{args.port}/')
        return
    with socket.socket() as probe:
        if probe.connect_ex(('127.0.0.1',args.port))==0:
            raise SystemExit(f'{args.port}端口已有旧网页或其它服务。关闭原网页/稳像服务窗口后重新启动“启动网页控制.cmd”。')
    options=['--port',str(args.port)]
    if args.no_browser:options.append('--no-browser')
    serve(options,browser_opener=open_supported_browser)

if __name__=='__main__':main()
