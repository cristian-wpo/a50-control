#!/bin/zsh
# Pruebas contra la base real (interruptor trasero en PC). Dejan la base como estaba.
# Uso: ./probar-con-la-base.sh      (compila el CLI si hace falta)
set -uo pipefail
cd "$(dirname "$0")"
swift build -c release --product a50ctl >/dev/null || { echo "no compila"; exit 1; }
B=.build/release/a50ctl

$B usb
if ! $B battery >/dev/null 2>&1; then
    echo "\nNo hay base A50 Gen 4 abierta (9886:002c): ponla en PC y vuelve a lanzarlo."
    exit 2
fi
fail=0
for t in "eq library test" "profile test" "diag selftest"; do
    echo "\n== a50ctl $t"
    $B ${=t} 2>&1 | tail -4 || fail=1
    [[ ${pipestatus[1]} -eq 0 ]] || fail=1
done
[[ $fail -eq 0 ]] && echo "\nTODO OK" || { echo "\nHAY FALLOS"; exit 1; }
