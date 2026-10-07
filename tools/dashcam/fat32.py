#!/usr/bin/env python3
"""Чтение SD-карты регистратора BYD без монтирования — только чтение.

Карта BYD размечена FAT32, но с неверным типом раздела, и macOS её не
монтирует. Читаем файловую систему сами: загрузочный сектор → FAT →
каталоги (с длинными именами LFN) → цепочки кластеров. На устройство
не пишется ни байта: файл открывается только на чтение.

    python3 fat32.py /dev/disk12s1                    — корень карты
    python3 fat32.py /dev/disk12s1 --list             — все файлы
    python3 fat32.py /dev/disk12s1 --copy DEST [--date 2026-10-07]
                                                      — ролики .mp4 в папку
"""
import argparse
import os
import struct
import sys

# Конец цепочки кластеров FAT32 (0x0FFFFFF8…0x0FFFFFFF).
_EOC = 0x0FFFFFF8
# Устройства /dev/disk* читаются только блоками, кратными сектору; берём 4 КБ.
_ALIGN = 4096


class FAT32:
    def __init__(self, path):
        self.f = open(path, 'rb', buffering=0)
        try:
            self._parse_bpb()
        except Exception:
            self.f.close()
            raise

    def _parse_bpb(self):
        bs = self.read(0, 512)
        if bs[510:512] != b'\x55\xaa':
            raise ValueError('нет сигнатуры загрузочного сектора 55AA — это не FAT32')
        self.bps = struct.unpack_from('<H', bs, 11)[0]
        self.spc = bs[13]
        self.reserved = struct.unpack_from('<H', bs, 14)[0]
        self.nfats = bs[16]
        self.fatsz = struct.unpack_from('<I', bs, 36)[0]
        self.root = struct.unpack_from('<I', bs, 44)[0]
        if not self.bps or not self.spc or not self.fatsz:
            raise ValueError('пустые поля BPB — это не FAT32')
        self.cluster = self.bps * self.spc
        self.data = (self.reserved + self.nfats * self.fatsz) * self.bps
        self.fat_off = self.reserved * self.bps
        self._fat = None

    def close(self):
        self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def read(self, off, size):
        start = off - off % _ALIGN
        end = off + size
        end += (-end) % _ALIGN
        self.f.seek(start)
        buf = self.f.read(end - start)
        return buf[off - start: off - start + size]

    def fat(self):
        if self._fat is None:
            raw = self.read(self.fat_off, self.fatsz * self.bps)
            raw = raw[: len(raw) - len(raw) % 4]
            self._fat = memoryview(raw).cast('I')
        return self._fat

    def chain(self, c):
        fat = self.fat()
        out = []
        while 2 <= c < _EOC and c < len(fat) and len(out) < 10_000_000:
            out.append(c)
            c = fat[c] & 0x0FFFFFFF
        return out

    def cluster_off(self, c):
        return self.data + (c - 2) * self.cluster

    def listdir(self, c):
        """Записи каталога: (имя, это_каталог, первый_кластер, размер, «ГГГГ-ММ-ДД чч:мм»)."""
        raw = b''.join(self.read(self.cluster_off(x), self.cluster) for x in self.chain(c))
        lfn = []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            if e[11] == 0x0F:
                part = e[1:11] + e[14:26] + e[28:32]
                lfn.insert(0, part.decode('utf-16le', 'ignore').split('\x00')[0].replace('￿', ''))
                continue
            base = e[0:8].decode('latin1').strip()
            ext = e[8:11].decode('latin1').strip()
            name = ''.join(lfn) if lfn else (base + ('.' + ext if ext else ''))
            lfn = []
            attr = e[11]
            if attr & 0x08:  # метка тома
                continue
            hi, lo = struct.unpack_from('<H', e, 20)[0], struct.unpack_from('<H', e, 26)[0]
            size = struct.unpack_from('<I', e, 28)[0]
            t, d = struct.unpack_from('<HH', e, 22)
            stamp = (f"{1980 + (d >> 9):04d}-{(d >> 5) & 15:02d}-{d & 31:02d} "
                     f"{t >> 11:02d}:{(t >> 5) & 63:02d}")
            yield name, bool(attr & 0x10), (hi << 16) | lo, size, stamp

    def walk(self, c=None, prefix=''):
        for name, isdir, cl, size, stamp in self.listdir(c or self.root):
            if name in ('.', '..'):
                continue
            yield prefix + name, isdir, cl, size, stamp
            if isdir and cl:
                yield from self.walk(cl, prefix + name + '/')

    def copy(self, cl, size, dest):
        """Копирует файл по цепочке кластеров; во временный файл, затем rename."""
        tmp = dest + '.part'
        with open(tmp, 'wb') as out:
            left = size
            for x in self.chain(cl):
                if left <= 0:
                    break
                chunk = self.read(self.cluster_off(x), min(self.cluster, left))
                out.write(chunk)
                left -= len(chunk)
        if left > 0:
            os.remove(tmp)
            raise IOError(f'цепочка кластеров короче размера файла: {dest}')
        os.replace(tmp, dest)


def copy_videos(fs, dest, date=None, log=print):
    """Копирует ролики .mp4 с карты в папку. Уже скопированные (то же имя и
    размер) пропускает — повторный импорт той же карты ничего не тянет заново.
    date — «ГГГГ-ММ-ДД»: только ролики, чьё имя начинается с этой даты."""
    os.makedirs(dest, exist_ok=True)
    copied = skipped = 0
    for path, isdir, cl, size, _stamp in fs.walk():
        name = path.rsplit('/', 1)[-1]
        if isdir or not name.lower().endswith('.mp4'):
            continue
        if date and not name.startswith(date):
            continue
        target = os.path.join(dest, name)
        if os.path.exists(target) and os.path.getsize(target) == size:
            skipped += 1
            continue
        fs.copy(cl, size, target)
        copied += 1
        log(f'скопирован {path} ({size / 1e6:.0f} МБ)')
    return copied, skipped


def main(argv=None):
    ap = argparse.ArgumentParser(description='Чтение карты BYD (FAT32) без монтирования')
    ap.add_argument('device')
    ap.add_argument('--list', action='store_true', help='все файлы рекурсивно')
    ap.add_argument('--copy', metavar='DEST', help='скопировать ролики .mp4 в папку')
    ap.add_argument('--date', help='только ролики этой даты (ГГГГ-ММ-ДД)')
    a = ap.parse_args(argv)
    with FAT32(a.device) as fs:
        if a.copy:
            copied, skipped = copy_videos(fs, a.copy, a.date)
            print(f'скопировано {copied}, уже было {skipped}')
            return
        print(f'кластер {fs.cluster} Б, корень {fs.root}')
        entries = fs.walk() if a.list else fs.listdir(fs.root)
        for path, isdir, _cl, size, stamp in entries:
            print(('D ' if isdir else 'F ') + f'{stamp}  {size:>12}  {path}')


if __name__ == '__main__':
    sys.exit(main())
