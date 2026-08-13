#!/usr/bin/env python3
"""JSON API: OKX P2P USDT price for a merchant, filtered by payment method.

Pure stdlib (http.server) -- no external dependencies.
A background thread refreshes OKX every REFRESH_SEC so GET /price is instant.

Config (in order of precedence: config.json in this dir, then env vars, then defaults):
  merchant  -> OKX nickname to track        (default "0x200x")
  fiat      -> quote currency                (default "USD")
  pay       -> payment-method substring      (default "ABA Bank"; use "all" for no filter)
  refresh   -> OKX poll interval in seconds  (default 60)

Endpoints (GET, JSON):
  /price    -> {buy_best, sell_best, ranges, rate, done, updated}
  /health   -> {ok, updated, error}
  /raw      -> full filtered ad list (diagnostics)

Run:
  python3 api_server.py --host 0.0.0.0 --port 8080
"""
from __future__ import annotations
import argparse, json, os, threading, time, urllib.request, urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://www.okx.com/v3/c2c/tradingOrders/books"


def load_config() -> dict:
    cfg = {"merchant": "0x200x", "fiat": "USD", "pay": "ABA Bank", "refresh": 60}
    here = os.path.dirname(os.path.abspath(__file__))
    cj = os.path.join(here, "config.json")
    if os.path.exists(cj):
        try:
            cfg.update(json.load(open(cj)))
        except Exception:
            pass
    cfg["merchant"] = os.getenv("MERCHANT", cfg["merchant"])
    cfg["fiat"] = os.getenv("FIAT", cfg["fiat"])
    cfg["pay"] = os.getenv("PAY", cfg["pay"])
    try:
        cfg["refresh"] = int(os.getenv("REFRESH_SEC", cfg["refresh"]))
    except ValueError:
        pass
    return cfg


C = load_config()
MERCHANT, FIAT, PAY, REFRESH_SEC = C["merchant"], C["fiat"], C["pay"], C["refresh"]

_state: dict = {"data": None, "updated": None, "error": None}
_lock = threading.Lock()


def _fetch_side(side: str) -> list[dict]:
    params = {
        "quoteCurrency": FIAT, "baseCurrency": "USDT", "side": side,
        "paymentMethod": "all", "userType": "all", "showTrade": "false",
        "showFollow": "false", "showAlreadyTraded": "false", "isAbleFilter": "false",
    }
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=25) as r:
        d = json.loads(r.read().decode())
    if d.get("code") != 0:
        raise RuntimeError(f"OKX API error: {d}")
    return d["data"].get(side, [])


def _filter(orders: list[dict]) -> list[dict]:
    out = [o for o in orders if o.get("nickName", "").lower() == MERCHANT.lower()]
    if PAY and PAY.lower() != "all":
        out = [o for o in out if PAY.lower() in [p.lower() for p in o.get("paymentMethods", [])]]
    return out


def _summarize() -> dict:
    buy = _filter(_fetch_side("buy"))
    sell = _filter(_fetch_side("sell"))
    if not buy and not sell:
        raise RuntimeError("merchant has no ads in this fiat/payment right now")
    rate = (buy or sell)[0].get("completedRate")
    done = (buy or sell)[0].get("completedOrderQuantity")

    def stats(ads, side):
        if not ads:
            return None
        prices = sorted(float(o["price"]) for o in ads)
        best = prices[-1] if side == "buy" else prices[0]
        return {"best": best, "range": [prices[0], prices[-1]],
                "ads": len(ads), "available": sum(float(o["availableAmount"]) for o in ads)}

    return {"merchant": MERCHANT, "fiat": FIAT, "payment": PAY,
            "buy": stats(buy, "buy"), "sell": stats(sell, "sell"),
            "completed_rate": rate, "completed_orders": done}


def _refresh_loop() -> None:
    while True:
        try:
            data = _summarize()
            with _lock:
                _state["data"], _state["updated"], _state["error"] = data, datetime.now(timezone.utc).isoformat(), None
        except Exception as e:  # noqa: BLE001
            with _lock:
                _state["error"] = str(e)
        time.sleep(REFRESH_SEC)


def _price_payload() -> tuple[int, dict]:
    with _lock:
        data, updated, error = _state["data"], _state["updated"], _state["error"]
    if data is None:
        return 503, {"error": "no data yet", "detail": error}
    return 200, {
        "merchant": data["merchant"], "fiat": data["fiat"], "payment": data["payment"],
        "buy_best": data["buy"]["best"] if data["buy"] else None,
        "sell_best": data["sell"]["best"] if data["sell"] else None,
        "buy_range": data["buy"]["range"] if data["buy"] else None,
        "sell_range": data["sell"]["range"] if data["sell"] else None,
        "buy_available": data["buy"]["available"] if data["buy"] else None,
        "sell_available": data["sell"]["available"] if data["sell"] else None,
        "completed_rate": data["completed_rate"], "completed_orders": data["completed_orders"],
        "updated": updated,
    }


class _H(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/price"):
            self._send(*_price_payload())
        elif path == "/health":
            with _lock:
                self._send(200, {"ok": True, "updated": _state["updated"], "error": _state["error"]})
        elif path == "/raw":
            with _lock:
                self._send(200, _state["data"] or {"error": _state["error"]})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()
    threading.Thread(target=_refresh_loop, daemon=True).start()
    time.sleep(1)
    print(f"OKX P2P API on http://{args.host}:{args.port}  (merchant={MERCHANT} pay={PAY})")
    ThreadingHTTPServer((args.host, args.port), _H).serve_forever()


if __name__ == "__main__":
    main()
