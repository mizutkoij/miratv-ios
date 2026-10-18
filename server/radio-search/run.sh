#!/bin/bash
# pm2 entry: low CPU / IO priority so a small box (and radio-web) is never starved
cd "$(dirname "$0")"
export HOST="${HOST:-192.0.2.20}" PORT="${PORT:-8091}"
exec nice -n 10 ionice -c3 python3 radio_search.py
