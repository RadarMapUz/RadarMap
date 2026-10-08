#!/usr/bin/env python3
"""Классификатор «камера близко» по векторам FeaturePrint участков кадра —
обучение «мешками» (multiple-instance), torch на MPS.

Запуск — питоном с torch: ~/RadarMapBuild/dashcam/lanes/venv/bin/python train.py …

    train.py fit [--fine] [--all]  — обучить на train-поездках (--all — на всех, для прогона);
                                     отчёт на val: по кадрам выборки dataset.py (та же,
                                     что у Create ML) и по событиям против GPX
    train.py predict [--fine]      — вероятность для кадров с векторами → camprob

--fine — мелкая сетка 9×3 плиток (features.py --fine), иначе 4 крупных участка.

Почему мешки: метка «камера близко» известна с точностью до пары секунд
(момент проезда восстановлен из wpt по пути, ±30–50 м) и до участка кадра
(камера то слева на столбе, то справа, то на консоли над полосой). Мешок
проезда — все кадры 0,2–4,5 с до проезда × все участки; «в мешке есть камера»
= максимум по нему. Отрицательные — каждый кадр сам по себе (максимум по
участкам должен быть мал). Так модель сама ищет кадр и участок с камерой,
вместо того чтобы учить «перекрёсток со светофором».
"""
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn

import common
import evaluate
import features
import passes

BAG_DT = (0.2, 4.5)
BAG_D = (4.0, 90.0)
SEED = 7


def model_path(fine, use_all):
    return os.path.join(common.OUT, f"mil{'_fine' if fine else ''}{'' if use_all else '_val'}.pt")


class Net(nn.Module):
    def __init__(self, regions, dim=features.DIM, hidden=128):
        super().__init__()
        self.reg = nn.Parameter(torch.zeros(regions, dim))
        self.f = nn.Sequential(nn.LayerNorm(dim), nn.Dropout(0.2), nn.Linear(dim, hidden), nn.ReLU(),
                               nn.Dropout(0.2), nn.Linear(hidden, 1))

    def forward(self, x):            # x: [B, R, D] → логит кадра [B], логиты участков [B, R]
        r = self.f(x.float() + self.reg).squeeze(-1)
        return r.max(dim=1).values, r


def build_sets(ctx, ids):
    """→ bags: [(trip, [строки X])], negs: [(trip, строка)]."""
    row = {int(i): k for k, i in enumerate(ids)}
    bags, negs = [], []
    for key, tps in ctx.gp.items():
        frs = [f for f in ctx.by_trip.get(key, []) if f['id'] in row]
        if not frs:
            continue
        odo = ctx.odo(key)
        pts = [t for t, _ in tps]
        for tp, _ in tps:
            bag = [row[f['id']] for f in frs
                   if BAG_DT[0] <= tp - f['t'] <= BAG_DT[1] and (f['kmh'] or 0) >= 3
                   and BAG_D[0] <= odo.at(tp) - odo.at(f['t']) <= BAG_D[1]]
            if bag:
                bags.append((key, bag))
        for f in frs:
            g = ctx.geo.get(f['id'])
            dist = ctx.grid.nearest_dist(g[0], g[1], 1000) if g else None
            if passes.label_negative(f['t'], f['kmh'], pts, odo, dist):
                negs.append((key, row[f['id']]))
    return bags, negs


def device():
    return torch.device('mps') if torch.backends.mps.is_available() else torch.device('cpu')


def fit(X, bags, negs, epochs=40, log=print):
    torch.manual_seed(SEED)
    rng = np.random.default_rng(SEED)
    dev = device()
    Xt = torch.from_numpy(X).to(dev)
    net = Net(X.shape[1]).to(dev)
    opt = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=1e-3)
    bce = nn.BCEWithLogitsLoss()
    neg_idx = np.array([i for _, i in negs])
    for ep in range(epochs):
        net.train()
        order = rng.permutation(len(bags))
        tot = 0.0
        for s in range(0, len(order), 32):
            chunk = [bags[k][1] for k in order[s:s + 32]]
            flat = torch.tensor([i for b in chunk for i in b], device=dev)
            fl, _ = net(Xt[flat])
            outs, o = [], 0
            for b in chunk:
                outs.append(fl[o:o + len(b)].max())
                o += len(b)
            pl = torch.stack(outs)
            nb = torch.from_numpy(rng.choice(neg_idx, size=len(chunk) * 4)).to(dev)
            nl, _ = net(Xt[nb])
            loss = bce(pl, torch.ones_like(pl)) + bce(nl, torch.zeros_like(nl))
            opt.zero_grad()
            loss.backward()
            opt.step()
            tot += loss.item()
        if ep % 10 == 9:
            log(f'эпоха {ep + 1}: loss {tot / max(1, len(order) // 32):.3f}')
    return net


@torch.no_grad()
def predict(net, X, batch=2048):
    net.eval()
    dev = device()
    out, reg = [], []
    for s in range(0, len(X), batch):
        fl, rl = net(torch.from_numpy(X[s:s + batch]).to(dev))
        out.append(torch.sigmoid(fl).cpu().numpy())
        reg.append(rl.argmax(dim=1).cpu().numpy())
    return np.concatenate(out), np.concatenate(reg)


def main(argv):
    fine, use_all = '--fine' in argv, '--all' in argv
    name = 'mil_fine' if fine else 'mil'
    ctx = evaluate.Ctx()
    ids, X = features.load(np, fine=fine)
    val = set(ctx.split()['val'])
    if argv[0] == 'fit':
        bags, negs = build_sets(ctx, ids)
        tb = [b for b in bags if use_all or b[0] not in val]
        tn = [n for n in negs if use_all or n[0] not in val]
        print('мешков', len(tb), 'отрицательных', len(tn))
        net = fit(X, tb, tn)
        torch.save(net.state_dict(), model_path(fine, use_all))
        prob, _ = predict(net, X)
        pd = {int(i): float(p) for i, p in zip(ids, prob)}
        rep = evaluate.report(ctx, pd, sorted(val), name + ('_all' if use_all else ''))
        rep['frames_train'] = evaluate.frame_eval(ctx, pd, 'train')
        rep['bags'], rep['negatives'] = len(tb), len(tn)
        print(json.dumps({k: v for k, v in rep.items()}, ensure_ascii=False, indent=1))
        common.save_report(ctx.conn, f"eval_{name}{'_all' if use_all else ''}", rep)
    elif argv[0] == 'predict':
        net = Net(X.shape[1]).to(device())
        net.load_state_dict(torch.load(model_path(fine, True), map_location=device()))
        prob, reg = predict(net, X)
        rows = [(int(i), ctx.fr[int(i)]['trip_key'], ctx.fr[int(i)]['t'], float(p), name)
                for i, p in zip(ids, prob) if int(i) in ctx.fr]
        with ctx.conn:
            ctx.conn.execute('DELETE FROM camprob WHERE model=?', (name,))
            ctx.conn.executemany('INSERT OR REPLACE INTO camprob(frame_id, trip_key, t, p, model) '
                                 'VALUES(?,?,?,?,?)', rows)
        np.save(os.path.join(common.OUT, f'{name}_region.npy'), np.stack([ids, reg]))
        print('кадров', len(rows))


if __name__ == '__main__':
    main(sys.argv[1:])
