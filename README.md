# okx-p2p-api

A tiny JSON API that tracks a merchant's **USDT buy/sell price on OKX P2P**, filtered
by payment method (e.g. ABA Bank). Built to watch one specific merchant, but the
config constants at the top of `api_server.py` make it trivial to retarget.

Pure Python standard library — **no pip install required**.

## Endpoints

| Method | Path     | Returns |
|--------|---------|---------|
| GET    | `/price` | Best buy & sell price, ranges, availability, merchant completion rate |
| GET    | `/health`| `{ok, updated, error}` |
| GET    | `/raw`   | Full filtered ad payload (diagnostics) |

Example:
```bash
curl http://localhost:8080/price
```
```json
{
  "merchant": "0x200x", "fiat": "USD", "payment": "ABA Bank",
  "buy_best": 0.992, "sell_best": 0.995,
  "buy_range": [0.99, 0.992], "sell_range": [0.995, 0.997],
  "buy_available": 7736.73, "sell_available": 11634.61,
  "completed_rate": "0.9916", "completed_orders": 13371,
  "updated": "2026-08-12T16:51:02Z"
}
```

## Run locally
```bash
python3 api_server.py --host 127.0.0.1 --port 8080
```

## Expose to the internet
```bash
chmod +x expose.sh
./expose.sh          # starts API on 0.0.0.0:8080, opens OS firewall, prints public URL
```
`expose.sh` starts the API, opens the **OS** firewall (ufw/iptables), prints your
public IP, and verifies inbound reachability. If inbound still fails, your **cloud
provider's security list / security group** is blocking it — open INGRESS TCP:8080
there (the script tells you exactly where).

## Configure (track a different merchant)
Edit the constants at the top of `api_server.py`:
```python
FIAT = "USD"        # quote currency
MERCHANT = "0x200x" # OKX nickname
PAY = "ABA Bank"    # payment-method substring to filter on
REFRESH_SEC = 60    # OKX poll interval (respect rate limits)
```

## Notes
- Read-only: hits OKX's public P2P API. No auth, no trading.
- No TLS: when exposed on a raw IP it is plain HTTP. Do not add secret/auth
  endpoints without putting it behind HTTPS (reverse proxy / host with TLS).
- The localhost.run trick (outbound SSH tunnel) also works if your cloud blocks
  inbound entirely.

## License
MIT — see LICENSE.
