#!/usr/bin/env python3
"""Тесты читателя FAT32 на синтетическом образе (не на настоящей карте).

Образ собирается здесь же: загрузочный сектор, две копии FAT, корневой
каталог с длинными именами (LFN), подкаталог, удалённая запись, метка тома
и файл на несколько кластеров с нецелым хвостом — всё, обо что читатель
спотыкался бы на карте BYD.
Запуск: python3 -m unittest discover -s tools/dashcam
"""
import os
import shutil
import struct
import tempfile
import unittest

import fat32

BPS, SPC, RESERVED, NFATS, NCLUSTERS = 512, 1, 32, 2, 128
FATSZ = (NCLUSTERS + 2) * 4 // BPS + 1
CL = BPS * SPC


class ImageBuilder:
    def __init__(self):
        self.fat = [0x0FFFFFF8, 0x0FFFFFFF] + [0] * NCLUSTERS
        self.clusters = {}
        self.next = 2

    def alloc(self, data):
        """Кладёт данные в цепочку кластеров — через один, чтобы цепочка
        была не подряд (так и бывает на заполненной карте)."""
        n = max(1, -(-len(data) // CL))
        chain = []
        for _ in range(n):
            chain.append(self.next)
            self.next += 2
        for i, c in enumerate(chain):
            self.fat[c] = chain[i + 1] if i + 1 < len(chain) else 0x0FFFFFFF
            self.clusters[c] = data[i * CL:(i + 1) * CL].ljust(CL, b'\0')
        return chain[0]

    @staticmethod
    def short(name83, attr, cluster, size, date=(2026, 10, 7), time=(8, 5)):
        e = bytearray(32)
        e[0:11] = name83.encode('latin1')
        e[11] = attr
        struct.pack_into('<H', e, 20, cluster >> 16)
        t = (time[0] << 11) | (time[1] << 5)
        d = ((date[0] - 1980) << 9) | (date[1] << 5) | date[2]
        struct.pack_into('<HH', e, 22, t, d)
        struct.pack_into('<H', e, 26, cluster & 0xFFFF)
        struct.pack_into('<I', e, 28, size)
        return bytes(e)

    @staticmethod
    def lfn(name):
        """Записи LFN в порядке хранения на диске (последний кусок первым)."""
        chars = name.encode('utf-16le')
        units = [chars[i:i + 2] for i in range(0, len(chars), 2)]
        units.append(b'\0\0')
        while len(units) % 13:
            units.append(b'\xff\xff')
        parts = [units[i:i + 13] for i in range(0, len(units), 13)]
        out = []
        for seq, p in enumerate(parts, start=1):
            e = bytearray(32)
            e[0] = seq | (0x40 if seq == len(parts) else 0)
            e[1:11] = b''.join(p[0:5])
            e[11] = 0x0F
            e[14:26] = b''.join(p[5:11])
            e[28:32] = b''.join(p[11:13])
            out.append(bytes(e))
        return list(reversed(out))

    def entry(self, long_name, name83, attr, cluster, size):
        return b''.join(self.lfn(long_name)) + self.short(name83, attr, cluster, size)

    def write(self, path, root_cluster):
        bs = bytearray(BPS)
        struct.pack_into('<H', bs, 11, BPS)
        bs[13] = SPC
        struct.pack_into('<H', bs, 14, RESERVED)
        bs[16] = NFATS
        struct.pack_into('<I', bs, 36, FATSZ)
        struct.pack_into('<I', bs, 44, root_cluster)
        bs[510:512] = b'\x55\xaa'
        fat = b''.join(struct.pack('<I', v) for v in self.fat).ljust(FATSZ * BPS, b'\0')
        img = bytearray(bs) + bytearray((RESERVED - 1) * BPS) + fat * NFATS
        data = bytearray(NCLUSTERS * CL)
        for c, blob in self.clusters.items():
            data[(c - 2) * CL:(c - 1) * CL] = blob
        with open(path, 'wb') as f:
            f.write(bytes(img) + bytes(data))


def build_image(path):
    b = ImageBuilder()
    video = bytes((i * 7) % 251 for i in range(3 * CL + 123))  # 4 кластера, хвост
    small = b'GPS'
    v1 = b.alloc(video)
    v2 = b.alloc(small)
    other = b.alloc(b'readme')
    sub = b.entry('2026-10-07-08-05-10.mp4', '2026-1~1MP4', 0x20, v1, len(video))
    sub += b.entry('2026-10-08-09-00-00.mp4', '2026-1~2MP4', 0x20, v2, len(small))
    sub += b.short('.          ', 0x10, 0, 0)
    sub_cl = b.alloc(sub)
    deleted = bytearray(b.short('DELETED MP4', 0x20, v2, 3))
    deleted[0] = 0xE5
    root = b.short('BYD_CARD   ', 0x08, 0, 0)  # метка тома
    root += bytes(deleted)
    root += b.entry('Normal', 'NORMAL     ', 0x10, sub_cl, 0)
    root += b.short('INFO    TXT', 0x20, other, 6)
    root_cl = b.alloc(root)
    b.write(path, root_cl)
    return video, small


class FAT32Test(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.img = os.path.join(self.dir, 'card.img')
        self.video, self.small = build_image(self.img)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_walk_long_names_and_skips(self):
        with fat32.FAT32(self.img) as fs:
            items = {p: (d, s, st) for p, d, _c, s, st in fs.walk()}
        self.assertEqual(set(items), {
            'Normal', 'INFO.TXT',
            'Normal/2026-10-07-08-05-10.mp4', 'Normal/2026-10-08-09-00-00.mp4'})
        self.assertTrue(items['Normal'][0])
        self.assertEqual(items['Normal/2026-10-07-08-05-10.mp4'][1], len(self.video))
        self.assertEqual(items['INFO.TXT'][2], '2026-10-07 08:05')

    def test_copy_multicluster_byte_exact(self):
        out = os.path.join(self.dir, 'out')
        with fat32.FAT32(self.img) as fs:
            copied, skipped = fat32.copy_videos(fs, out, log=lambda *_: None)
        self.assertEqual((copied, skipped), (2, 0))
        with open(os.path.join(out, '2026-10-07-08-05-10.mp4'), 'rb') as f:
            self.assertEqual(f.read(), self.video)
        self.assertFalse([n for n in os.listdir(out) if n.endswith('.part')])

    def test_copy_is_idempotent_and_filters_date(self):
        out = os.path.join(self.dir, 'out')
        with fat32.FAT32(self.img) as fs:
            self.assertEqual(fat32.copy_videos(fs, out, date='2026-10-07', log=lambda *_: None), (1, 0))
            self.assertEqual(fat32.copy_videos(fs, out, date='2026-10-07', log=lambda *_: None), (0, 1))
        self.assertEqual(os.listdir(out), ['2026-10-07-08-05-10.mp4'])

    def test_not_fat(self):
        junk = os.path.join(self.dir, 'junk.img')
        with open(junk, 'wb') as f:
            f.write(b'\0' * 4096)
        with self.assertRaises(ValueError):
            fat32.FAT32(junk)

    def test_source_is_opened_read_only(self):
        with open(self.img, 'rb') as f:
            before = f.read()
        with fat32.FAT32(self.img) as fs:
            self.assertEqual(fs.f.mode, 'rb')
            list(fs.walk())
        with open(self.img, 'rb') as f:
            self.assertEqual(f.read(), before)


if __name__ == '__main__':
    unittest.main()
