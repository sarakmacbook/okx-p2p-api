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

PORT="${PORT:-80}"
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

# --- merchant + fiat first ---
if [[ -n "${MERCHANT:-}" ]]; then M="$MERCHANT"; else ask "OKX merchant nickname to track" "0x200x"; M="$REPLY"; fi
if [[ -n "${FIAT:-}" ]];      then F="$FIAT";      else ask "Fiat/quote currency (USD EUR TRY CNY RUB INR NGN VND IDR ZAR PHP UAH)" "USD"; F="$REPLY"; fi

# --- fetch merchant's live ads to discover their real payment methods ---
echo "==> Looking up '$M' on OKX P2P ($F) ..."
PAYMENTS="$(python3 - "$M" "$F" <<'PY'
import sys, json, urllib.request, urllib.parse
m, f = sys.argv[1], sys.argv[2]
def fetch(side):
    params={"quoteCurrency":f,"baseCurrency":"USDT","side":side,"paymentMethod":"all","userType":"all","showTrade":"false","showFollow":"false","showAlreadyTraded":"false","isAbleFilter":"false"}
    url="https://www.okx.com/v3/c2c/tradingOrders/books?"+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers={"User-Agent":"Mozilla/5.0","Accept":"application/json"})
    return json.loads(urllib.request.urlopen(req,timeout=25).read().decode())["data"].get(side,[])
ads=[o for o in fetch("buy")+fetch("sell") if o.get("nickName","").lower()==m.lower()]
if not ads:
    print("__NONE__")
    sys.exit(2)
methods=sorted({x for o in ads for x in o.get("paymentMethods",[])})
print(json.dumps(methods))
PY
)"
if [[ "$PAYMENTS" == "__NONE__" ]]; then
  echo "  ! No live ads found for merchant '$M' in $F."
  echo "    Check the nickname/spelling and fiat. (OKX only exposes a merchant when they"
  echo "    have a LIVE ad in the fiat you query.) Aborting."
  exit 2
fi
echo "  found merchant. completion rate: $(python3 - "$M" "$F" <<'PY'
import sys,json,urllib.request,urllib.parse
m,f=sys.argv[1],sys.argv[2]
def fetch(s):
    p={"quoteCurrency":f,"baseCurrency":"USDT","side":s,"paymentMethod":"all","userType":"all","showTrade":"false","showFollow":"false","showAlreadyTraded":"false","isAbleFilter":"false"}
    u="https://www.okx.com/v3/c2c/tradingOrders/books?"+urllib.parse.urlencode(p)
    r=urllib.request.Request(u,headers={"User-Agent":"Mozilla/5.0","Accept":"application/json"})
    return json.loads(urllib.request.urlopen(r,timeout=25).read().decode())["data"].get(s,[])
o=next((x for x in fetch("buy")+fetch("sell") if x.get("nickName","").lower()==m.lower()),None)
print(o.get("completedRate"),"  completed orders:",o.get("completedOrderQuantity")) if o else print("?")
PY
)"

# --- payment method: show numbered list, let user pick ---
mapfile -t PMETHODS < <(python3 -c "import json,sys; [print(x) for x in json.loads('$PAYMENTS')]")
echo
echo "  Payment methods available for '$M':"
for i in "${!PMETHODS[@]}"; do echo "    $((i+1))) ${PMETHODS[$i]}"; done
echo "    $((${#PMETHODS[@]}+1))) all (no filter)"
if [[ -n "${PAY:-}" ]]; then
  P="$PAY"   # env preset (substring match)
elif [[ -n "${PAY_IDX:-}" ]]; then
  idx=$((PAY_IDX-1)); P="${PMETHODS[$idx]:-all}"
else
  read -r -p "Select payment method [1-$((${#PMETHODS[@]}+1)), default 1]: " CHOICE || true
  CHOICE="${CHOICE:-1}"
  if [[ "$CHOICE" == "$((${#PMETHODS[@]}+1))" ]] || [[ "${CHOICE,,}" == "all" ]]; then P="all"
  elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le "${#PMETHODS[@]}" ]]; then P="${PMETHODS[$((CHOICE-1))]}"
  else P="${PMETHODS[0]}"; fi
fi
echo "  -> tracking payment: $P"

# --- remaining prompts ---
if [[ -n "${PORT_ARG:-}" ]];  then PORT="$PORT_ARG"; else ask "Listen port" "80"; PORT="$REPLY"; fi
if [[ -n "${DOMAIN:-}" ]];    then D="$DOMAIN"; else ask "Custom domain to use (leave blank if none)" ""; D="$REPLY"; fi
if [[ -n "${REFRESH_ARG:-}" ]]; then REFRESH="$REFRESH_ARG"; else ask "Refresh interval in seconds (OKX poll)" "60"; REFRESH="$REPLY"; fi
if ! [[ "$REFRESH" =~ ^[0-9]+$ ]] || [[ "$REFRESH" -lt 10 ]]; then
  echo "  ! refresh must be an integer >= 10 (to respect OKX rate limits). Using 60."
  REFRESH=60
fi

echo
echo "==> Validating selection ..."
# re-fetch and confirm the chosen payment actually has ads
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
    print(f"  ! No ads for '{m}' in {f} with payment '{p}'. Try 'all' or another method.")
    sys.exit(2)
def line(ads,side):
    if not ads: print(f"  {side}: no ads"); return
    pr=sorted(float(o['price']) for o in ads)
    print(f"  {side}: best {'%.4f'%pr[-1] if side=='buy' else '%.4f'%pr[0]}  range {pr[0]:.4f}-{pr[-1]:.4f}  ({len(ads)} ads)")
line(buy,"BUY"); line(sell,"SELL")
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
RUN="python3 $DIR/api_server.py --host $HOST --port $PORT"
if [[ "$PORT" -lt 1024 ]]; then RUN="sudo $RUN"; fi   # privileged port needs root
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "    API already running (pid $(cat "$PIDFILE"))"
else
  nohup $RUN >"$DIR/api.log" 2>&1 &
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

# --- domain guidance ---
if [[ -n "$D" ]]; then
  echo "==> Custom domain: $D"
  if [[ "$PORT" == "80" ]]; then
    echo "    Add this DNS record to use your domain:"
    echo "      Type: A    Name: $D    Value: $PUB_IP    TTL: 300"
    echo "    Then access: http://$D/price"
  else
    echo "    Port $PORT is not 80, so a plain A record won't serve on :80."
    echo "    Either re-run with port 80, or add:"
    echo "      Type: A    Name: $D    Value: $PUB_IP    TTL: 300"
    echo "    and access: http://$D:$PORT/price"
  fi
  echo "    (This is plain HTTP. For HTTPS on your domain, put a reverse proxy /"
  echo "     ACME in front, or use a host with managed TLS.)"
fi

echo "Done. Logs: $DIR/api.log   Stop: kill $(cat $DIR/.api.pid)"
