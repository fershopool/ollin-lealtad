#!/usr/bin/env bash
# Prueba local de Quetzalito: carga quetzalito.sql en una BD temporal,
# corre pruebas.sql y una prueba de carrera fuera de transaccion.
set -euo pipefail

export PATH="/Applications/Postgres.app/Contents/Versions/latest/bin:$PATH"
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-54329}"
export PGUSER="${PGUSER:-postgres}"

BD="quetzalito_test"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARJETA_CARRERA="11111111-2222-3333-4444-555555555555"
TMP="$(mktemp -d)"

fallo() {
  echo "FALLA: $*" >&2
  exit 1
}

limpiar() {
  psql -d postgres -q -X -c "drop database if exists $BD with (force);" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap limpiar EXIT

[ -f "$DIR/quetzalito.sql" ] || fallo "no existe $DIR/quetzalito.sql"
[ -f "$DIR/pruebas.sql" ] || fallo "no existe $DIR/pruebas.sql"

# BD temporal y roles de Supabase (anon, authenticated)
psql -d postgres -X -v ON_ERROR_STOP=1 -q -c "drop database if exists $BD with (force);"
psql -d postgres -X -v ON_ERROR_STOP=1 -q -c "create database $BD encoding 'UTF8' template template0;"
psql -d postgres -X -v ON_ERROR_STOP=1 -q <<'SQL'
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
SQL

psql -d "$BD" -X -v ON_ERROR_STOP=1 -q <<'SQL'
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
-- Imita los privilegios por defecto de Supabase: sin los revoke de quetzalito.sql, anon alcanzaría tablas y funciones.
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
SQL

# Esquema y pruebas de transaccion
psql -d "$BD" -X -v ON_ERROR_STOP=1 -q -f "$DIR/quetzalito.sql" || fallo "quetzalito.sql no carga"
psql -d "$BD" -X -v ON_ERROR_STOP=1 -q -f "$DIR/pruebas.sql" || fallo "pruebas.sql fallo (ver FALLA arriba)"

# ---------- Carrera 1: 20 reclamos del mismo token ----------
psql -d "$BD" -X -v ON_ERROR_STOP=1 -q <<'SQL'
insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, lat, lng, activa, tope_hora, distribuidor)
values ('00000000-0000-0000-0000-0000000000ca', 'Cafe Carrera', 'Escuela Carrera', 'cafe-carrera',
        extensions.crypt('333333', extensions.gen_salt('bf')), 19.4, -99.1, true, 1000, true);
SQL

CODIGO="$(psql -d "$BD" -X -At -v ON_ERROR_STOP=1 -c "select public.crear_venta('333333')->>'codigo';")" \
  || fallo "crear_venta de la prueba de carrera"
[ -n "$CODIGO" ] || fallo "crear_venta no devolvio codigo en la prueba de carrera"

for i in $(seq 1 20); do
  psql -d "$BD" -X -At -c "select coalesce(public.reclamar('$CODIGO', null)->>'error', 'OK');" \
    > "$TMP/r_$i.out" 2> "$TMP/r_$i.err" &
done
wait

TOTAL_R=$(cat "$TMP"/r_*.out | wc -l | tr -d ' ')
OK_R=$(cat "$TMP"/r_*.out | grep -cx 'OK' || true)
USADO_R=$(cat "$TMP"/r_*.out | grep -cx 'token_usado' || true)
if [ "$TOTAL_R" -ne 20 ] || [ "$OK_R" -ne 1 ] || [ "$USADO_R" -ne 19 ]; then
  cat "$TMP"/r_*.err >&2 || true
  fallo "carrera de reclamar: total=$TOTAL_R/20, ok=$OK_R (esperado 1), token_usado=$USADO_R (esperado 19). Salida: $(cat "$TMP"/r_*.out | tr '\n' ' ')"
fi
echo "carrera reclamar: 1 ok y 19 token_usado"

# ---------- Carrera 2: 10 canjes del mismo codigo ----------
psql -d "$BD" -X -v ON_ERROR_STOP=1 -q <<'SQL'
insert into public.tarjetas (id, creada_en) values ('11111111-2222-3333-4444-555555555555', now());
insert into public.tokens (id, cafeteria_id, codigo, creado_en, expira_en, usado_en, tarjeta_id)
select gen_random_uuid(), c.id, encode(extensions.gen_random_bytes(6), 'hex'), now(), now() + interval '5 minutes',
       now(), '11111111-2222-3333-4444-555555555555'
from public.cafeterias c, generate_series(1, 6)
where c.slug = 'cafe-carrera';
insert into public.sellos (id, tarjeta_id, cafeteria_id, token_id, creado_en)
select gen_random_uuid(), t.tarjeta_id, t.cafeteria_id, t.id, now()
from public.tokens t
where t.tarjeta_id = '11111111-2222-3333-4444-555555555555';
SQL

CANJE="$(psql -d "$BD" -X -At -v ON_ERROR_STOP=1 -c "select public.pedir_canje('$TARJETA_CARRERA')->>'codigo';")" \
  || fallo "pedir_canje de la prueba de carrera"
[[ "$CANJE" =~ ^[0-9]{6}$ ]] || fallo "pedir_canje no devolvio codigo de 6 digitos (salida: '$CANJE')"

for i in $(seq 1 10); do
  psql -d "$BD" -X -At -c "select coalesce(public.canjear('333333', '$CANJE')->>'error', 'OK');" \
    > "$TMP/c_$i.out" 2> "$TMP/c_$i.err" &
done
wait

TOTAL_C=$(cat "$TMP"/c_*.out | wc -l | tr -d ' ')
OK_C=$(cat "$TMP"/c_*.out | grep -cx 'OK' || true)
USADO_C=$(cat "$TMP"/c_*.out | grep -cx 'canje_usado' || true)
if [ "$TOTAL_C" -ne 10 ] || [ "$OK_C" -ne 1 ] || [ "$USADO_C" -ne 9 ]; then
  cat "$TMP"/c_*.err >&2 || true
  fallo "carrera de canjear: total=$TOTAL_C/10, ok=$OK_C (esperado 1), canje_usado=$USADO_C (esperado 9). Salida: $(cat "$TMP"/c_*.out | tr '\n' ' ')"
fi
echo "carrera canjear: 1 ok y 9 canje_usado"

# ---------- Carrera 3: tope por hora con 20 ventas simultaneas (pgbench: 20 clientes a la vez) ----------
psql -d "$BD" -X -v ON_ERROR_STOP=1 -q <<'SQL'
insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, activa, tope_hora)
values ('00000000-0000-0000-0000-0000000000cb', 'Cafe Tope', 'Escuela Tope', 'cafe-tope',
        extensions.crypt('555555', extensions.gen_salt('bf')), true, 5);
SQL
echo "select public.crear_venta('555555');" > "$TMP/tope.sql"
pgbench -n -c 20 -j 4 -t 1 -f "$TMP/tope.sql" "$BD" >/dev/null 2>&1 || fallo "pgbench de la carrera del tope"
TOKENS_TOPE=$(psql -d "$BD" -X -At -c "select count(*) from public.tokens where cafeteria_id = '00000000-0000-0000-0000-0000000000cb'")
[ "$TOKENS_TOPE" = "5" ] || fallo "carrera del tope: $TOKENS_TOPE tokens con 20 ventas simultaneas (esperado 5)"
echo "carrera tope: 5 tokens de 20 ventas simultaneas"

# ---------- Carrera 4: limite de intentos con 40 PIN incorrectos a la vez (al final: bloquea todo) ----------
echo "select public.entrar('000000');" > "$TMP/pin.sql"
pgbench -n -c 40 -j 8 -t 1 -f "$TMP/pin.sql" "$BD" >/dev/null 2>&1 || fallo "pgbench de la carrera del PIN"
FALLOS=$(psql -d "$BD" -X -At -c "select count(*) from public.fallos_pin")
[ "$FALLOS" = "30" ] || fallo "carrera del PIN: $FALLOS fallos registrados con 40 intentos simultaneos (esperado exactamente 30)"
echo "carrera PIN: exactamente 30 fallos de 40 intentos simultaneos"

echo "OK: todas las pruebas pasaron"
