#!/usr/bin/env bash
#
# expose.sh -- install & expose the OKX P2P price API.
#
# During install it ASKS which OKX merchant / fiat / payment method to track,
# validates the merchant actually has live ads on OKX, writes config.json, then
# starts the API bound to 0.0.0.0:PORT, opens the OS firewall, and verifies
# inbound reachability.
#
# Non-interactive override (skips prompts):
#   MERCHANT=0x200x FIAT=USD PAY="ABA Bank" ./expose.sh
#
# Note: OS firewall open is necessary but NOT sufficient on most clouds
# (Oracle/AWS/GCP). You must ALSO allow inbound TCP:PORT in the provider's
# security list / security group. The script detects and tells you when needed.
#
set -euo pipefail

PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$DIR/.api.pid"
CFGFILE="$DIR/config.json"

ask() {  # ask <prompt> <default>  -> sets REPLY
  local prompt="$1" def="$2"
  if [[ -n "${3:-}" ]]; then REPLY="$3"; return; fi   # 3rd arg = preset (non-interactive)
  read -r -p "$prompt [$def]: " REPLY || true
  REPLY="${REPLY:-$def}"
}

echo "=============================================="
echo " OKX P2P price API -- setup"
echo "=============================================="

# --- interactive prompts (skipped if env vars set) ---
if [[ -n "${MERCHANT:-}" ]]; then M="$MERCHANT"; else ask "OKX merchant nickname to track" "0x200x"; M="$REPLY"; fi
if [[ -n "${FIAT:-}" ]];      then F="$FIAT";      else ask "Fiat/quote currency (USD EUR TRY CNY RUB INR NGN VND IDR ZAR PHP UAH)" "USD"; F="$REPLY"; fi
if [[ -n "${PAY:-}" ]];       then P="$PAY";        else ask "Payment method to filter (e.g. 'ABA Bank'; 'all' for no filter)" "ABA Bank"; P="$REPLY"; fi
REFRESH="${REFRESH_SEC:-60}"

echo
echo "==> Validating merchant '$M' on OKX P2P ($F) ..."
# hit the live API for both sides, filter by merchant(+pay), report what we find
python3 - "$M" "$F" "$P" <<'PY'
import sys, json, urllib.request, urllib.parse
m, f, p = sys.argv[1], sys.argv[2], sys.argv[3]
def fetch(side):
    params={"quoteCurrency":f,"baseCurrency":"USDT","side":side,"paymentMethod":"all","userType":"all","showTrade":"false","showFollow":"false","showAlreadyTraded":"false","isAbleFilter":"false"}
    url="https://www.okx.com/v3/c2c/tradingOrders/books?"+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers={"User-Agent":"Mozilla/5.0","Accept":"application/json"})
    return json.loads(urllib.request.urlopen(req,timeout=25).read().decode())["data"].get(side,[])
def filt(orders):
    out=[o for o in orders if o.get("nickName","").lower()==m.lower()]
    if p.lower()!="all": out=[o for o in out if p.lower() in [x.lower() for x in o.get("paymentMethods",[])]]
    return out
buy=filt(fetch("buy")); sell=filt(fetch("sell"))
if not buy and not sell:
    print(f"  ! No ads found for merchant '{m}' in {f} with payment '{p}'.")
    print("    Check the nickname/spelling, fiat, and payment method. (The OKX orders API")
    print("    only exposes a merchant when they have a LIVE ad in the fiat you query.)")
    sys.exit(2)
def line(ads,side):
    if not ads: print(f"  {side}: no ads"); return
    pr=sorted(float(o['price']) for o in ads)
    print(f"  {side}: best {'%.4f'%pr[-1] if side=='buy' else '%.4f'%pr[0]}  range {pr[0]:.4f}-{pr[-1]:.4f}  ({len(ads)} ads)")
print(f"  Found merchant '{m}':")
line(buy,"BUY"); line(sell,"SELL")
if buy or sell:
    o=(buy or sell)[0]
    print(f"  completion rate: {o.get('completedRate')}   completed orders: {o.get('completedOrderQuantity')}")
PY
echo "  validation OK."

# --- write config ---
cat > "$CFGFILE" <<JSON
{
  "merchant": "$M",
  "fiat": "$F",
  "pay": "$P",
  "refresh": $REFRESH
}
JSON
echo "==> wrote $CFGFILE"

# --- start API ---
echo "==> Starting API on $HOST:$PORT"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "    API already running (pid $(cat "$PIDFILE"))"
else
  nohup python3 "$DIR/api_server.py" --host "$HOST" --port "$PORT" >"$DIR/api.log" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 2
  echo "    started pid $(cat "$PIDFILE")"
fi

# --- firewall ---
echo "==> Opening OS firewall for TCP/$PORT"
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow "$PORT/tcp" || echo "    (ufw allow failed -- run manually or ufw inactive)"
elif command -v iptables >/dev/null 2>&1; then
  sudo iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || echo "    (iptables failed -- run manually)"
else
  echo "    no ufw/iptables found; skipping OS firewall"
fi

# --- public IP + verify ---
echo "==> Detecting public IP"
PUB_IP="$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://ifconfig.me || echo UNKNOWN)"
echo "    public IP: $PUB_IP"
echo "    URL:       http://$PUB_IP:$PORT/price"

echo "==> Verifying inbound reachability"
sleep 1
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "http://$PUB_IP:$PORT/price" || echo 000)"
if [[ "$CODE" == "200" ]]; then
  echo "    OK ($CODE) -- reachable at http://$PUB_IP:$PORT/price"
else
  echo "    NOT reachable ($CODE). OS firewall is open but the CLOUD provider still blocks"
  echo "    inbound. Allow INGRESS TCP:$PORT from 0.0.0.0/0 in your cloud console:"
  echo "      Oracle: Networking > Security Lists > Add Ingress Rule (TCP, $PORT)"
  echo "      AWS:    EC2 > Security Groups > Inbound > Custom TCP $PORT"
  echo "      GCP:    VPC > Firewall > allow tcp:$PORT"
fi

echo "==> Local health:"
curl -s --max-time 8 "http://127.0.0.1:$PORT/health" || true
echo
echo "Done. Logs: $DIR/api.log   Stop: kill \$(cat $DIR/.api.pid)"
