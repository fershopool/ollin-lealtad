-- pruebas.sql: pruebas del backend Quetzalito, segun CONTRATO.md.
-- Todo corre dentro de una transaccion que se revierte al final.
-- Sin metacomandos de psql: sirve para el editor SQL de Supabase y para psql.

begin;

-- ============ Auxiliares ============

create function pg_temp.chk(cond boolean, msg text)
returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then
    raise exception 'FALLA: %', msg;
  end if;
end $$;

create function pg_temp.debe_ok(r json, msg text)
returns void language plpgsql as $$
begin
  perform pg_temp.chk(r->>'ok' = 'true', msg || ' | respuesta: ' || coalesce(r::text, 'null'));
end $$;

create function pg_temp.debe_err(r json, codigo text, msg text)
returns void language plpgsql as $$
begin
  perform pg_temp.chk(r->>'ok' = 'false' and r->>'error' = codigo,
    msg || ' | esperaba error ' || codigo || ' | respuesta: ' || coalesce(r::text, 'null'));
end $$;

create function pg_temp.nueva_venta(p_pin text)
returns text language plpgsql as $$
declare r json := public.crear_venta(p_pin);
begin
  perform pg_temp.debe_ok(r, 'crear_venta con PIN ' || p_pin || ' debe ser ok');
  return r->>'codigo';
end $$;

create function pg_temp.reclamar_ok(p_codigo text, p_tarjeta uuid, msg text)
returns text language plpgsql as $$
declare r json := public.reclamar(p_codigo, p_tarjeta);
begin
  perform pg_temp.debe_ok(r, msg);
  return r->>'tarjeta_id';
end $$;

create function pg_temp.repetido_ok(p_codigo text, p_tarjeta uuid, p_saldo int)
returns void language plpgsql as $$
declare r json := public.reclamar(p_codigo, p_tarjeta);
begin
  perform pg_temp.chk(r->>'ok' = 'true' and r->>'repetido' = 'true' and (r->>'sellos')::int = p_saldo,
    'la misma tarjeta repitiendo debe dar ok con repetido=true y saldo ' || p_saldo || ' | respuesta: ' || coalesce(r::text, 'null'));
end $$;

create function pg_temp.saldo(p_tarjeta uuid)
returns int language plpgsql as $$
declare r json := public.tarjeta(p_tarjeta);
begin
  perform pg_temp.debe_ok(r, 'tarjeta ' || p_tarjeta::text || ' debe existir');
  return (r->>'sellos')::int;
end $$;

create function pg_temp.sembrar_sello(p_tarjeta uuid, p_caf uuid)
returns void language plpgsql as $$
declare tid uuid := gen_random_uuid();
begin
  insert into public.tokens (id, cafeteria_id, codigo, creado_en, expira_en, usado_en, tarjeta_id)
  values (tid, p_caf, encode(extensions.gen_random_bytes(6), 'hex'), now(), now() + interval '5 minutes', now(), p_tarjeta);
  insert into public.sellos (id, tarjeta_id, cafeteria_id, token_id, creado_en)
  values (gen_random_uuid(), p_tarjeta, p_caf, tid, now());
end $$;

create function pg_temp.pedir_canje_ok(p_tarjeta uuid)
returns text language plpgsql as $$
declare r json := public.pedir_canje(p_tarjeta);
begin
  perform pg_temp.debe_ok(r, 'pedir_canje debe ser ok');
  perform pg_temp.chk(r->>'codigo' ~ '^[0-9]{6}$', 'el codigo de canje debe tener 6 digitos | respuesta: ' || r::text);
  perform pg_temp.chk(r->>'expira_en' is not null, 'pedir_canje debe devolver expira_en');
  return r->>'codigo';
end $$;

create function pg_temp.metrica(p_dias int, p_slug text, p_campo text)
returns int language plpgsql as $$
declare
  m json := public.metricas('admin-prueba', p_dias);
  v text;
begin
  perform pg_temp.chk(m->>'ok' = 'true', 'metricas debe ser ok | respuesta: ' || coalesce(m::text, 'null'));
  select e->>p_campo into v from json_array_elements(m->'filas') e where e->>'slug' = p_slug;
  perform pg_temp.chk(v is not null, 'metricas no trae la fila ' || p_slug);
  return v::int;
end $$;

create function pg_temp.esperar_fila(p_dias int, p_slug text, v_ventas int, v_reclamos int, v_canjes int, v_tarjetas int)
returns void language plpgsql as $$
begin
  perform pg_temp.chk(pg_temp.metrica(p_dias, p_slug, 'ventas') = v_ventas, p_slug || ': ventas esperadas ' || v_ventas);
  perform pg_temp.chk(pg_temp.metrica(p_dias, p_slug, 'reclamos') = v_reclamos, p_slug || ': reclamos esperados ' || v_reclamos);
  perform pg_temp.chk(pg_temp.metrica(p_dias, p_slug, 'canjes') = v_canjes, p_slug || ': canjes esperados ' || v_canjes);
  perform pg_temp.chk(pg_temp.metrica(p_dias, p_slug, 'tarjetas_nuevas') = v_tarjetas, p_slug || ': tarjetas_nuevas esperadas ' || v_tarjetas);
end $$;

-- Las pruebas cuentan filas: corre este archivo con las tablas vacías (antes de sembrar cafeterías reales)
-- o en un proyecto de prueba. Todo se revierte al final, pero con datos reales los conteos no cuadrarían.
select pg_temp.chk((select count(*) from public.cafeterias) = 0 and (select count(*) from public.tarjetas) = 0,
  'la base debe estar vacia: corre pruebas.sql antes de sembrar cafeterias reales');

-- ============ Siembra ============
-- Cafeteria A: PIN 111111, escuela "Escuela Uno".
-- Cafeteria B: PIN 222222, escuela "Escuela Dos".
-- Cafeteria C (sin actividad) se siembra en la prueba j.

insert into public.config (clave, valor) values
  ('meta', '6'),
  ('admin_hash', extensions.crypt('admin-prueba', extensions.gen_salt('bf')))
on conflict (clave) do update set valor = excluded.valor;

insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, lat, lng, activa, tope_hora) values
  ('00000000-0000-0000-0000-00000000000a', 'Cafe A', 'Escuela Uno', 'cafe-a',
   extensions.crypt('111111', extensions.gen_salt('bf')), 19.43, -99.13, true, 30),
  ('00000000-0000-0000-0000-00000000000b', 'Cafe B', 'Escuela Dos', 'cafe-b',
   extensions.crypt('222222', extensions.gen_salt('bf')), 19.44, -99.14, true, 30);

-- ============ a) Un token sirve una sola vez ============
select set_config('qz.c1', pg_temp.nueva_venta('111111'), true);
select set_config('qz.t1', pg_temp.reclamar_ok(current_setting('qz.c1'), null, 'a: primer reclamo con tarjeta nueva debe ser ok'), true);
select set_config('qz.cb', pg_temp.nueva_venta('222222'), true);
select set_config('qz.t2', pg_temp.reclamar_ok(current_setting('qz.cb'), null, 'a: tarjeta nueva en B debe ser ok'), true);
select pg_temp.debe_err(public.reclamar(current_setting('qz.c1'), current_setting('qz.t2')::uuid), 'token_usado',
  'a: otra tarjeta sobre un token ya usado');
select pg_temp.repetido_ok(current_setting('qz.c1'), current_setting('qz.t1')::uuid, 1);
select pg_temp.chk((select count(*) from public.sellos where tarjeta_id = current_setting('qz.t1')::uuid) = 1,
  'a: el repetido no debe insertar un sello nuevo');

-- ============ b) Token vencido e inexistente ============
select set_config('qz.c3', pg_temp.nueva_venta('111111'), true);
update public.tokens set expira_en = now() - interval '1 minute' where codigo = current_setting('qz.c3');
select pg_temp.debe_err(public.reclamar(current_setting('qz.c3'), null), 'token_vencido', 'b: token vencido');
select pg_temp.debe_err(public.reclamar('no-existe-000000', null), 'token_invalido', 'b: token inexistente');
select pg_temp.chk((select count(*) from public.tarjetas) = 2, 'b: un reclamo fallido no debe crear tarjeta');

-- ============ c) Tope por hora ============
update public.cafeterias set tope_hora = 2 where id = '00000000-0000-0000-0000-00000000000a';
update public.tokens set creado_en = now() - interval '2 hours' where cafeteria_id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.nueva_venta('111111');
select pg_temp.nueva_venta('111111');
select pg_temp.debe_err(public.crear_venta('111111'), 'tope_hora', 'c: tercera venta de A con tope_hora=2');
select pg_temp.debe_ok(public.crear_venta('222222'), 'c: la otra cafeteria debe seguir vendiendo');
update public.cafeterias set tope_hora = 30 where id = '00000000-0000-0000-0000-00000000000a';

-- ============ d) Regla de 10 minutos ============
select set_config('qz.c4', pg_temp.nueva_venta('111111'), true);
select pg_temp.debe_err(public.reclamar(current_setting('qz.c4'), current_setting('qz.t1')::uuid), 'sello_reciente',
  'd: segundo sello de la misma cafeteria dentro de 10 minutos');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 1, 'd: sello_reciente no debe cambiar el saldo');
select set_config('qz.c5', pg_temp.nueva_venta('222222'), true);
select pg_temp.debe_ok(public.reclamar(current_setting('qz.c5'), current_setting('qz.t1')::uuid),
  'd: la regla es por cafeteria; un sello en B no debe bloquearse por A');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 2, 'd: saldo 2 tras el sello en B');
update public.sellos set creado_en = now() - interval '11 minutes'
  where tarjeta_id = current_setting('qz.t1')::uuid and cafeteria_id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.debe_ok(public.reclamar(current_setting('qz.c4'), current_setting('qz.t1')::uuid),
  'd: pasados 11 minutos el sello debe acreditarse');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 3, 'd: saldo 3 tras acreditar a los 11 minutos');

-- ============ e) Canje: exige la meta de sellos ============
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 3, 'e: precondicion, saldo 3');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 5, 'e: saldo 5');
select pg_temp.chk((public.tarjeta(current_setting('qz.t1')::uuid)->>'premio_listo') = 'false', 'e: con 5 sellos premio_listo debe ser false');
select pg_temp.debe_err(public.pedir_canje(current_setting('qz.t1')::uuid), 'faltan_sellos', 'e: pedir canje con 5 sellos');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 6, 'e: saldo 6');
select pg_temp.chk((public.tarjeta(current_setting('qz.t1')::uuid)->>'premio_listo') = 'true', 'e: con 6 sellos premio_listo debe ser true');
select set_config('qz.canje1', pg_temp.pedir_canje_ok(current_setting('qz.t1')::uuid), true);
select pg_temp.chk(public.pedir_canje(current_setting('qz.t1')::uuid)->>'codigo' = current_setting('qz.canje1'),
  'e: pedir otra vez debe devolver el mismo codigo');
select pg_temp.chk((select count(*) from public.canjes where tarjeta_id = current_setting('qz.t1')::uuid) = 1,
  'e: no debe crearse un segundo canje vigente');
select pg_temp.debe_err(public.pedir_canje(gen_random_uuid()), 'tarjeta_invalida', 'e: pedir_canje con tarjeta inexistente');
select pg_temp.debe_err(public.tarjeta(gen_random_uuid()), 'tarjeta_invalida', 'e: tarjeta() con tarjeta inexistente');

-- ============ f) Un codigo de canje sirve una sola vez ============
select pg_temp.debe_ok(public.canjear('111111', current_setting('qz.canje1')), 'f: canje valido debe ser ok');
select pg_temp.chk((select cafeteria_id from public.canjes where codigo = current_setting('qz.canje1')) = '00000000-0000-0000-0000-00000000000a'::uuid,
  'f: el canje debe registrar la cafeteria que canjeo');
select pg_temp.chk((select usado_en is not null from public.canjes where codigo = current_setting('qz.canje1')),
  'f: el canje debe quedar con usado_en');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 0, 'f: el saldo debe bajar en 6 (de 6 a 0)');
select pg_temp.debe_err(public.canjear('111111', current_setting('qz.canje1')), 'canje_usado', 'f: segundo intento con el mismo codigo');

-- ============ g) Canje vencido e invalido ============
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.sembrar_sello(current_setting('qz.t1')::uuid, '00000000-0000-0000-0000-00000000000b');
select pg_temp.chk(pg_temp.saldo(current_setting('qz.t1')::uuid) = 6, 'g: saldo 6 tras 6 sellos nuevos (12 sellos, 1 canje usado)');
select set_config('qz.canje2', pg_temp.pedir_canje_ok(current_setting('qz.t1')::uuid), true);
update public.canjes set creado_en = now() - interval '6 minutes' where codigo = current_setting('qz.canje2');
select pg_temp.debe_err(public.canjear('111111', current_setting('qz.canje2')), 'canje_vencido', 'g: canje con mas de 5 minutos');
select pg_temp.debe_err(public.canjear('111111', 'ZZZZZZ'), 'canje_invalido', 'g: codigo de canje inexistente');

-- ============ i) Seguridad: anon ============
-- anon no debe leer ni escribir tablas directamente.
set local role anon;
do $$
declare
  t text;
  filtrado text := '';
begin
  foreach t in array array['cafeterias', 'tarjetas', 'tokens', 'sellos', 'canjes', 'config', 'fallos_pin'] loop
    begin
      execute format('select 1 from public.%I limit 1', t);
      filtrado := filtrado || ' lectura de ' || t;
    exception when insufficient_privilege then
      null;
    end;
    begin
      execute format('insert into public.%I default values', t);
      filtrado := filtrado || ' escritura en ' || t;
    exception when insufficient_privilege then
      null;
    end;
  end loop;
  if filtrado <> '' then
    raise exception 'FALLA: anon tiene acceso directo a:%', filtrado;
  end if;
end $$;
-- anon si debe poder vender por la funcion.
select set_config('qz.anon_ok', public.crear_venta('222222')->>'ok', true);
reset role;
select pg_temp.chk(current_setting('qz.anon_ok') = 'true', 'i: anon debe poder llamar crear_venta');
select pg_temp.chk(not exists (
  select 1 from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and left(p.proname, 1) = '_'
    and has_function_privilege('anon', p.oid, 'EXECUTE')
), 'i: anon no debe poder ejecutar funciones auxiliares que empiezan con _');

-- ============ j) metricas ============
select pg_temp.debe_err(public.metricas('clave-mal', null::int), 'clave_invalida', 'j: clave incorrecta');
insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, lat, lng, activa, tope_hora) values
  ('00000000-0000-0000-0000-00000000000c', 'Cafe C', 'Escuela Tres', 'cafe-c',
   extensions.crypt('444444', extensions.gen_salt('bf')), 19.45, -99.15, true, 30);
select pg_temp.debe_ok(public.metricas('admin-prueba', null::int), 'j: clave correcta debe ser ok');
select pg_temp.chk(json_array_length(public.metricas('admin-prueba', null::int)->'filas') = 3,
  'j: una fila por cafeteria (3, incluida la que no tuvo actividad)');
-- Conteos esperados con todo el escenario anterior (p_dias null):
--   A: ventas 5 (c1, c3, dos de c, c4), reclamos 2 (dos sellos de T1), canjes 1 (canje1), tarjetas_nuevas 1 (T1)
--   B: ventas 13 (cb, uno de c, c5, 9 sellos sembrados, anon), reclamos 11 (T2, c5, 9 sembrados), canjes 0, tarjetas_nuevas 1 (T2)
--   C: todo 0
select pg_temp.esperar_fila(null::int, 'cafe-a', 5, 2, 1, 1);
select pg_temp.esperar_fila(null::int, 'cafe-b', 13, 11, 0, 1);
select pg_temp.esperar_fila(null::int, 'cafe-c', 0, 0, 0, 0);
-- Filtro por dias: los eventos de A quedan a 3 dias; con p_dias=1 no deben contar.
update public.tokens set creado_en = now() - interval '3 days' where cafeteria_id = '00000000-0000-0000-0000-00000000000a';
update public.sellos set creado_en = now() - interval '3 days' where cafeteria_id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.chk(pg_temp.metrica(1, 'cafe-a', 'ventas') = 0, 'j: con p_dias=1 cafe-a no debe contar ventas de hace 3 dias');
select pg_temp.chk(pg_temp.metrica(1, 'cafe-a', 'reclamos') = 0, 'j: con p_dias=1 cafe-a no debe contar reclamos de hace 3 dias');
select pg_temp.chk(pg_temp.metrica(1, 'cafe-b', 'ventas') = 13, 'j: con p_dias=1 cafe-b sigue con 13 ventas');
select pg_temp.chk(pg_temp.metrica(1, 'cafe-b', 'reclamos') = 11, 'j: con p_dias=1 cafe-b sigue con 11 reclamos');

-- ============ k) PIN repetido entre cafeterias activas ============
-- Si dos cafeterias comparten PIN ninguna debe entrar: una venta nunca se atribuye a la equivocada.
insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, activa) values
  ('00000000-0000-0000-0000-00000000000d', 'Cafe D', 'Escuela Cuatro', 'cafe-d',
   extensions.crypt('111111', extensions.gen_salt('bf')), true);
select pg_temp.debe_err(public.entrar('111111'), 'pin_invalido', 'k: un PIN compartido por dos cafeterias activas no debe entrar a ninguna');
update public.cafeterias set activa = false where id = '00000000-0000-0000-0000-00000000000d';
select pg_temp.debe_ok(public.entrar('111111'), 'k: con una sola cafeteria activa con ese PIN vuelve a entrar');

-- ============ h) PIN incorrecto y bloqueo (al final: los 30 fallos bloquean todo) ============
select pg_temp.debe_err(public.entrar('000000'), 'pin_invalido', 'h: entrar con PIN incorrecto');
select pg_temp.debe_err(public.crear_venta('000000'), 'pin_invalido', 'h: crear_venta con PIN incorrecto');
select pg_temp.debe_err(public.canjear('000000', current_setting('qz.canje2')), 'pin_invalido', 'h: canjear con PIN incorrecto');
select pg_temp.debe_ok(public.entrar('111111'), 'h: entrar con PIN correcto antes del bloqueo');
select pg_temp.chk(public.entrar('111111')->>'escuela' = 'Escuela Uno', 'h: entrar debe devolver la escuela');
insert into public.fallos_pin (creado_en) select now() from generate_series(1, 30);
select set_config('qz.ntok', (select count(*) from public.tokens)::text, true);
select pg_temp.debe_err(public.entrar('111111'), 'bloqueado', 'h: entrar con PIN correcto tras 30 fallos');
select pg_temp.debe_err(public.crear_venta('111111'), 'bloqueado', 'h: crear_venta con PIN correcto tras 30 fallos');
select pg_temp.chk((select count(*) from public.tokens)::text = current_setting('qz.ntok'),
  'h: una crear_venta bloqueada no debe crear token');
select pg_temp.debe_err(public.canjear('111111', current_setting('qz.canje2')), 'bloqueado', 'h: canjear con PIN correcto tras 30 fallos');
select pg_temp.debe_err(public.metricas('admin-prueba', null::int), 'bloqueado', 'h: metricas con clave correcta tras 30 fallos');

-- Todo lo anterior se revierte; el veredicto va al final porque el editor de Supabase solo muestra el último resultado.
rollback;
select 'TODAS LAS PRUEBAS PASARON' as resultado;
