#!/usr/bin/env bash
# Revisa de punta a punta si el módulo ya está conectado: DNS, HTTPS, páginas y Supabase. No escribe nada.
# Uso: bash verificar.sh        (desde la carpeta del repo)
cd "$(dirname "${BASH_SOURCE[0]}")"
D=lealtad.ollin.digital
PEND=0
ok() { echo "  ✔ $1"; }
falta() { echo "  ✘ $1"; PEND=$((PEND + 1)); }

echo "1) DNS"
cname=$(dig +short CNAME "$D" | head -1)
[ "$cname" = "fershopool.github.io." ] && ok "$D apunta a fershopool.github.io" \
  || falta "falta el CNAME «lealtad» → fershopool.github.io en Cloudflare (Proxy: DNS only)"

echo "2) Páginas por HTTPS"
for p in "" caja/ c/ panel/ negocio/ mostrador/; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$D/$p")
  [ "$code" = "200" ] && ok "https://$D/$p" || falta "https://$D/$p responde «$code» (000 = aún sin DNS o sin certificado)"
done
redir=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "http://$D/caja/")
case "$redir" in 301*https://*) ok "HTTP redirige a HTTPS (Enforce HTTPS activo)";; *) falta "falta activar «Enforce HTTPS» en GitHub → Settings → Pages (respuesta: $redir)";; esac

echo "3) Supabase"
url=$(sed -n 's/.*url: "\(.*\)".*/\1/p' config.js)
key=$(sed -n 's/.*key: "\(.*\)".*/\1/p' config.js)
resp=$(curl -s --max-time 15 -X POST "$url/rest/v1/rpc/tarjeta" -H "apikey: $key" -H 'Content-Type: application/json' \
  -d "{\"p_tarjeta\":\"$(uuidgen | tr 'A-Z' 'a-z')\"}")
case "$resp" in *tarjeta_invalida*) ok "el proyecto responde (y no está pausado)";; *) falta "Supabase no responde como se espera: $resp";; esac
acao=$(curl -s -o /dev/null -D - --max-time 15 -X OPTIONS "$url/rest/v1/rpc/reclamar" -H "Origin: https://$D" \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: apikey,content-type' | grep -i -c 'access-control-allow-origin')
[ "$acao" -ge 1 ] && ok "Supabase acepta peticiones desde https://$D" || falta "Supabase no devuelve CORS para https://$D"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url/rest/v1/cafeterias?select=*" -H "apikey: $key")
[ "$code" = "401" ] && ok "las tablas siguen cerradas al público (401)" || falta "ALERTA: la tabla cafeterias responde $code sin PIN"

echo
[ "$PEND" -eq 0 ] && echo "TODO CONECTADO: ya puedes probar con el celular (LEEME-LUNES.md, paso 3)." \
  || echo "Faltan $PEND cosa(s); arregla la primera ✘ de arriba y vuelve a correr: bash verificar.sh"
exit $PEND
