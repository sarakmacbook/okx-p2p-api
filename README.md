# okx-p2p-api

A tiny JSON API that tracks a merchant's **USDT buy/sell price on OKX P2P**, filtered
by payment method (e.g. ABA Bank). Built to watch one specific merchant, but the
install prompts make it trivial to retarget to any merchant/fiat/payment.

Pure Python standard library — **no pip install required**.

## Endpoints

| Method | Path     | Returns |
|--------|---------|---------|
| GET    | `/price` | Best buy & sell price, ranges, availability, merchant completion rate |
| GET    | `/health`| `{ok, updated, error}` |
| GET    | `/raw`   | Full filtered ad payload (diagnostics) |

Example:
```bash
curl http://localhost/price        # or :8080 if you chose a different port
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

## Install & expose (asks you what to track)

```bash
chmod +x expose.sh
./expose.sh
```

During install it interactively asks:

1. **OKX merchant nickname** to track (e.g. `0x200x`)
2. **Fiat / quote currency** (USD EUR TRY CNY RUB INR NGN VND IDR ZAR PHP UAH)
3. **Payment method** to filter on (e.g. `ABA Bank`; `all` for no filter)
4. **Listen port** (default **80**; ports below 1024 start with `sudo`)
5. **Custom domain** (optional — leave blank if you don't have one)

It then **validates the merchant has live ads on OKX** (aborts with a clear message if
not), writes `config.json`, starts the API on `0.0.0.0:PORT`, opens the **OS** firewall
(ufw/iptables), prints your public IP, and verifies inbound reachability. If inbound still
fails, your **cloud provider's security list / security group** is blocking it — open
INGRESS TCP:PORT there (the script tells you exactly where).

If you gave a domain, it prints the DNS `A` record to point at your public IP:
```
Type: A    Name: your.domain    Value: <public-ip>    TTL: 300
```
then access `http://your.domain/price` (port 80) or `http://your.domain:PORT/price`.

Non-interactive override (skips prompts):
```bash
MERCHANT=0x200x FIAT=USD PAY="ABA Bank" PORT_ARG=80 DOMAIN=api.example.com ./expose.sh
```

## Run locally (no exposure)

```bash
python3 api_server.py --host 127.0.0.1 --port 8080
```

## Configure

Settings live in `config.json` (created by `expose.sh`), overridable by env vars
(`MERCHANT`, `FIAT`, `PAY`, `REFRESH_SEC`):
```json
{ "merchant": "0x200x", "fiat": "USD", "pay": "ABA Bank", "refresh": 60 }
```
`pay: "all"` disables the payment-method filter. `refresh` is the OKX poll interval
in seconds (keep ≥ 30 to respect rate limits).

## Notes
- Read-only: hits OKX's public P2P API. No auth, no trading.
- No TLS: when exposed on a raw IP or domain it is plain HTTP. Do not add secret/auth
  endpoints without putting it behind HTTPS (reverse proxy / host with TLS).
- The localhost.run trick (outbound SSH tunnel) also works if your cloud blocks
  inbound entirely.

## License
MIT — see LICENSE.
