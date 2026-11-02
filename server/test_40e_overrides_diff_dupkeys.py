"""Ревью 40E: overrides_diff.py разбирал payload не так, как телефон. Python
json берёт ПОСЛЕДНИЙ дубль ключа, JSONDecoder (Foundation) — ПЕРВЫЙ (проверено
бинарником). Владелец видел одно, подписывал байты, телефон применял другое.

Запуск: python3 -m unittest test_40e_overrides_diff_dupkeys  (из server/)
"""
import io, json, os, sys, tempfile, unittest, contextlib
SERVER = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SERVER)
import overrides_diff  # noqa: E402


def run(payload_text, cameras):
    with tempfile.TemporaryDirectory() as tmp:
        new = os.path.join(tmp, "p.json"); cam = os.path.join(tmp, "c.json")
        open(new, "w", encoding="utf-8").write(payload_text)
        json.dump(cameras, open(cam, "w", encoding="utf-8"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = overrides_diff.main(["--new", new, "--cameras", cam])
        return code, out.getvalue()


CAMERAS = [{"id": i, "lat": 41.3, "lon": 69.2, "type": "Стационар радар", "location": f"ул. {i}"}
           for i in range(1, 1001)]


class DuplicateKeys(unittest.TestCase):
    def test_duplicate_items_key_hides_cameras_behind_an_empty_diff(self):
        # Телефон возьмёт ПЕРВЫЙ items: 50 скрытий (5 % от 1000 — isSane пропустит).
        hides = ",".join('{"id":%d,"op":"hide"}' % i for i in range(1, 51))
        payload = '{"version":3,"items":[%s],"items":[]}' % hides
        code, out = run(payload, CAMERAS)
        self.assertNotEqual(code, 0, "дубль ключа — payload не по контракту; а отчёт:\n" + out)

    def test_duplicate_op_key_shows_retype_but_phone_hides(self):
        payload = '{"version":3,"items":[{"id":7,"op":"hide","op":"retype","type":"Стационар радар"}]}'
        code, out = run(payload, CAMERAS)
        self.assertNotIn("тип Стационар радар → Стационар радар", out,
                         "владелец видит смену типа, телефон применит hide")
        self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
