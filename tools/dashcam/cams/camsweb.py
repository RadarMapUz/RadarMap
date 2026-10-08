"""Данные вкладки «Камеры» для serve.py: список кандидатов и вырезки.

serve.py зовёт только эти две функции — остальное этапа живёт в cams/.
"""
import json
import os
import re

OUT = os.path.expanduser('~/RadarMapBuild/dashcam/cams')
UI_JSON = os.path.join(OUT, 'cams_ui.json')
CROPS = os.path.join(OUT, 'crops')
NAME_RE = re.compile(r'(new|gone)_\d+\.jpg')


def ui_data():
    if not os.path.exists(UI_JSON):
        return {'new': [], 'removed': [], 'summary': None, 'reports': {},
                'note': 'прогона ещё не было: python3 cams/run.py candidates'}
    with open(UI_JSON) as f:
        return json.load(f)


def crop_bytes(name):
    """Только имена вида new_123.jpg / gone_123.jpg из каталога вырезок."""
    if not NAME_RE.fullmatch(name):
        return None
    path = os.path.join(CROPS, name)
    if not os.path.isfile(path):
        return None
    with open(path, 'rb') as f:
        return f.read()
