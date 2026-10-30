"""Operate/capture only Calendula's own Android UI during an authorized USB check."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'output/device'
OUTPUT.mkdir(parents=True, exist_ok=True)
PACKAGE = 'app.calendula.calendula'
sys.stdout.reconfigure(encoding='utf-8')
SERIAL = os.environ.get('CALENDULA_DEVICE')
if not SERIAL:
    devices = subprocess.check_output(['adb', 'devices'], timeout=15).decode().splitlines()[1:]
    authorized = [line.split()[0] for line in devices if len(line.split()) > 1 and line.split()[1] == 'device']
    if len(authorized) != 1:
        raise RuntimeError('Connect one authorized phone or set CALENDULA_DEVICE.')
    SERIAL = authorized[0]
def adb(*args):
    return subprocess.check_output(['adb', '-s', SERIAL, *args], timeout=35).decode('utf-8', errors='replace')
def guard():
    focus = '\n'.join(line for line in adb('shell', 'dumpsys', 'window').splitlines() if 'mCurrentFocus=' in line)
    if PACKAGE not in focus:
        raise RuntimeError('Calendula is not foreground; refusing to read or operate another screen.')
def snapshot(name='current', capture=False):
    guard()
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/calendula-ui.xml')
    adb('pull', '/data/local/tmp/calendula-ui.xml', str(OUTPUT / f'{name}.xml'))
    root = ET.parse(OUTPUT / f'{name}.xml')
    nodes = [node for node in root.iter('node') if node.get('package') == PACKAGE]
    if capture:
        guard()
        adb('shell', 'screencap', '-p', '/data/local/tmp/calendula-screen.png')
        adb('pull', '/data/local/tmp/calendula-screen.png', str(OUTPUT / f'{name}.png'))
    return nodes
def tap(node, long_press=False):
    guard()
    x1,y1,x2,y2 = map(int, re.findall(r'\d+',node.get('bounds')))
    x,y=str((x1+x2)//2),str((y1+y2)//2)
    if long_press: adb('shell','input','swipe',x,y,x,y,'900')
    else: adb('shell','input','tap',x,y)
def find_label(nodes,label):
    for n in nodes:
        if n.get('text') == label or label in n.get('content-desc', '').split('\n'):
            return n
    raise RuntimeError(f'Control not found in Calendula: {label}')

if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('action',choices=['snapshot','tap','longpress','field','text','swipe','back','restart'])
    p.add_argument('value',nargs='?',default='current')
    p.add_argument('--capture',action='store_true')
    args=p.parse_args()
    if args.action=='snapshot':
        for n in snapshot(args.value,args.capture):
            label=n.get('text') or n.get('content-desc')
            if label or n.get('class')=='android.widget.EditText':
                print(repr((label,n.get('class'),n.get('clickable'),n.get('bounds'))))
    elif args.action in ('tap','longpress'):
        tap(find_label(snapshot(),args.value),args.action=='longpress')
    elif args.action=='field':
        tap([n for n in snapshot() if n.get('class')=='android.widget.EditText'][int(args.value)])
    elif args.action=='text':
        if not re.fullmatch(r'[A-Za-z0-9 ]{1,80}',args.value): raise RuntimeError('Only bounded test text is allowed')
        guard();adb('shell','input','text',args.value.replace(' ','%s'))
    elif args.action=='swipe':
        guard();adb('shell','input','swipe','720','2330','720','800','400')
    elif args.action=='back':
        guard();adb('shell','input','keyevent','4')
    elif args.action=='restart':
        guard();adb('shell','am','force-stop',PACKAGE);adb('shell','am','start','-W','-n',f'{PACKAGE}/.MainActivity')
