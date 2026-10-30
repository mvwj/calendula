"""Select only the known test CSV in Calendula's system picker.

No picker screenshot or directory inventory is saved or printed. Unknown file
names are discarded. Requires the picker to have been opened from Calendula.
"""
import argparse
import re
import xml.etree.ElementTree as ET
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

spec = spec_from_file_location('device_smoke', Path(__file__).with_name('device-smoke.py'))
device = module_from_spec(spec)
spec.loader.exec_module(device)
ALLOWED = {'com.google.android.documentsui', 'com.android.documentsui', 'com.oplus.documentsui', 'com.coloros.filemanager'}
LABELS = {'Show roots', 'Open navigation drawer', 'Downloads', 'Download', 'Recent',
          '下载', '最近', 'CalendulaTest', 'schedule-test.csv', 'Use this folder', '手机存储', '内部存储', '全部', '文档', 'Phone storage', 'Internal storage', 'All files', 'Documents', 'Search', 'Back', 'Files', 'Recents', 'Cancel'}

def guard():
    focus = '\n'.join(line for line in device.adb('shell', 'dumpsys', 'window').splitlines() if 'mCurrentFocus=' in line)
    standard = any(package + '/' in focus for package in ALLOWED if package != 'com.coloros.filemanager')
    oppo = 'com.coloros.filemanager/com.oplus.filemanager.picker.PickerActivity' in focus
    if not (standard or oppo):
        raise RuntimeError('Calendula file picker is not foreground.')

def nodes():
    guard()
    path = '/data/local/tmp/calendula-picker.xml'
    device.adb('shell', 'uiautomator', 'dump', path)
    data = device.adb('exec-out', 'cat', path)
    device.adb('shell', 'rm', '-f', path)
    guard()
    return [n for n in ET.fromstring(data).iter('node') if n.get('package') in ALLOWED]

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=['inspect', 'tap', 'text'])
    p.add_argument('label', nargs='?')
    args = p.parse_args()
    current = nodes()
    if args.action == 'inspect':
        for n in current:
            label = n.get('text') or n.get('content-desc')
            if label in LABELS or n.get('resource-id', '').endswith(':id/roots_toolbar') or n.get('class') in {'android.widget.Button', 'android.widget.ImageButton'}:
                print(repr((label, n.get('resource-id'), n.get('bounds'))))
    elif args.action == 'text':
        if args.label != 'schedule-test.csv': raise RuntimeError('Only the synthetic CSV filename may be searched.')
        fields = [n for n in current if n.get('class') == 'android.widget.EditText']
        if not fields: raise RuntimeError('No search field is shown in the file picker.')
        guard()
        x1,y1,x2,y2 = map(int,re.findall(r'\d+', fields[0].get('bounds')))
        device.adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
        device.adb('shell','input','text',args.label)
    else:
        if args.label not in LABELS: raise RuntimeError('Only the known task file or picker navigation may be selected.')
        match = next((n for n in current if n.get('text') == args.label or n.get('content-desc') == args.label), None)
        if match is None: raise RuntimeError('Known picker control not found: ' + args.label)
        guard()
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', match.get('bounds')))
        device.adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
