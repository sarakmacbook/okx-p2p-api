#!/usr/bin/env bash
#
# expose.sh -- start the OKX P2P price API and make it reachable from the internet.
#
# What it does:
#   1. Starts api_server.py bound to 0.0.0.0:PORT (background).
#   2. Tries to open the OS firewall (ufw, else iptables) for PORT.
#   3. Prints the public IP and the URL to hit.
#   4. Verifies inbound reachability (curl from the public IP). If it fails,
#      it explains the cloud-security-list step the user must do in their console.
#
# NOTE: the OS firewall step is necessary but NOT sufficient on most clouds
# (Oracle/AWS/GCP). You must ALSO allow inbound TCP:PORT in the provider's
# security list / security group. The script detects and tells you when that's
# still needed.
#
set -euo pipefail

PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="$DIR/.api.pid"

echo "==> Starting API on $HOST:$PORT"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "    API already running (pid $(cat "$PIDFILE"))"
else
  nohup python3 "$DIR/api_server.py" --host "$HOST" --port "$PORT" \
    >"$DIR/api.log" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 2
  echo "    started pid $(cat "$PIDFILE")"
fi

echo "==> Opening OS firewall for TCP/$PORT"
if command -v ufw >/dev/null 2>&1; then
  echo "    ufw detected -> sudo ufw allow $PORT/tcp"
  sudo ufw allow "$PORT/tcp" || echo "    (ufw allow failed -- run manually or ufw inactive)"
elif command -v iptables >/dev/null 2>&1; then
  echo "    iptables -> sudo iptables -I INPUT -p tcp --dport $PORT -j ACCEPT"
  sudo iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || echo "    (iptables failed -- run manually)"
else
  echo "    no ufw/iptables found; skipping OS firewall"
fi

echo "==> Detecting public IP"
PUB_IP="$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://ifconfig.me || echo UNKNOWN)"
echo "    public IP: $PUB_IP"
echo "    URL:       http://$PUB_IP:$PORT/price"

echo "==> Verifying inbound reachability"
sleep 1
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "http://$PUB_IP:$PORT/price" || echo 000)"
if [[ "$CODE" == "200" ]]; then
  echo "    OK ($CODE) -- reachable from the internet at http://$PUB_IP:$PORT/price"
else
  echo "    NOT reachable ($CODE)."
  echo "    The OS firewall is open, but the CLOUD provider is still blocking inbound."
  echo "    In your cloud console, allow INGRESS TCP:$PORT from 0.0.0.0/0:"
  echo "      - Oracle: Networking > Security Lists > Add Ingress Rule (TCP, $PORT)"
  echo "      - AWS:    EC2 > Security Groups > Inbound > Custom TCP $PORT"
  echo "      - GCP:    VPC > Firewall > allow tcp:$PORT"
  echo "    Then re-run this script (or just curl http://$PUB_IP:$PORT/price) to confirm."
fi

echo "==> Local health:"
curl -s --max-time 8 "http://127.0.0.1:$PORT/health" || true
echo
echo "Done. Logs: $DIR/api.log   Stop: kill \$(cat $DIR/.api.pid)"
