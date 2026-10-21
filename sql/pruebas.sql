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
declare r json := public.crear_venta(p_pin, true);
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

insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, lat, lng, activa, tope_hora, distribuidor) values
  ('00000000-0000-0000-0000-00000000000a', 'Cafe A', 'Escuela Uno', 'cafe-a',
   extensions.crypt('111111', extensions.gen_salt('bf')), 19.43, -99.13, true, 30, true),
  ('00000000-0000-0000-0000-00000000000b', 'Cafe B', 'Escuela Dos', 'cafe-b',
   extensions.crypt('222222', extensions.gen_salt('bf')), 19.44, -99.14, true, 30, true);

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

-- ============ l) Tarjeta con uuid del cliente (reintento idempotente) ============
select set_config('qz.u', gen_random_uuid()::text, true);
select set_config('qz.cu', pg_temp.nueva_venta('222222'), true);
select pg_temp.chk((public.reclamar(current_setting('qz.cu'), current_setting('qz.u')::uuid)->>'tarjeta_id') = current_setting('qz.u'),
  'l: una tarjeta nueva con uuid del cliente debe crearse con ese mismo id');
select pg_temp.repetido_ok(current_setting('qz.cu'), current_setting('qz.u')::uuid, 1);
select pg_temp.chk((select count(*) from public.sellos where tarjeta_id = current_setting('qz.u')::uuid) = 1,
  'l: el reintento con el mismo uuid no debe sumar otro sello');
select set_config('qz.cu2', pg_temp.nueva_venta('111111'), true);
select pg_temp.chk((public.reclamar(current_setting('qz.cu2'), current_setting('qz.u')::uuid)->>'nueva') = 'false',
  'l: con una tarjeta que ya existe, nueva debe ser false');
select pg_temp.chk((select count(*) from public.sellos where tarjeta_id = current_setting('qz.u')::uuid) = 2,
  'l: el segundo token (otra cafeteria) suma el segundo sello a la misma tarjeta');

-- ============ m) Valores extremos y limpieza ============
update public.config set valor = '0' where clave = 'meta';
select pg_temp.chk(public._meta() = 1, 'm: meta 0 debe tratarse como 1 (nunca premios sin sellos)');
update public.config set valor = '-5' where clave = 'meta';
select pg_temp.chk(public._meta() = 1, 'm: meta negativa debe tratarse como 1');
update public.config set valor = '6' where clave = 'meta';
select pg_temp.debe_ok(public.metricas('admin-prueba', 3000000), 'm: p_dias enorme no debe romper metricas');
select pg_temp.debe_ok(public.metricas('admin-prueba', -3), 'm: p_dias negativo no debe romper metricas');
insert into public.fallos_pin (creado_en) values (now() - interval '2 days');
select pg_temp.debe_err(public.entrar('000000'), 'pin_invalido', 'm: un PIN malo se registra como fallo');
select pg_temp.chk((select count(*) from public.fallos_pin where creado_en < now() - interval '1 day') = 0,
  'm: los fallos de mas de un dia se purgan');

-- ============ n) crear_cafeteria (alta desde el panel) ============
select set_config('qz.f0', (select count(*) from public.fallos_pin)::text, true);
select pg_temp.debe_err(public.crear_cafeteria('clave-mal', 'Cafe N', 'Escuela N', '555000'), 'clave_invalida', 'n: clave incorrecta');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.f0')::int + 1, 'n: una clave incorrecta se registra como fallo');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', '  ', 'Escuela N', '555000'), 'datos_invalidos', 'n: nombre vacio');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'X', 'Escuela N', '555000'), 'datos_invalidos', 'n: nombre de una letra');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', null, 'Escuela N', '555000'), 'datos_invalidos', 'n: nombre nulo');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', repeat('x', 81), 'Escuela N', '555000'), 'datos_invalidos', 'n: nombre de mas de 80');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Sin Escuela', '', '555999'), 'n: la escuela es opcional');
select pg_temp.chk((select slug from public.cafeterias where nombre = 'Cafe Sin Escuela') = 'cafe-sin-escuela', 'n: el slug sin escuela no lleva guion final');
select pg_temp.debe_ok(public.eliminar_cafeteria('admin-prueba', 'cafe-sin-escuela'), 'n: limpiar la cafeteria sin escuela');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', repeat('x', 41), '555000'), 'datos_invalidos', 'n: escuela de mas de 40');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', '12345'), 'pin_formato', 'n: PIN de 5 digitos');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', '1234567'), 'pin_formato', 'n: PIN de 7 digitos');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', 'abcdef'), 'pin_formato', 'n: PIN con letras');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', E'123456\n'), 'pin_formato', 'n: PIN con salto de linea');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', null), 'pin_formato', 'n: PIN nulo');
select pg_temp.chk((select count(*) from public.cafeterias where nombre = 'Cafe N') = 0, 'n: ningun dato invalido debe crear cafeteria');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.f0')::int + 1, 'n: los datos invalidos con clave correcta no registran fallos');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', '222222'), 'pin_repetido', 'n: PIN igual al de otra cafeteria activa');
insert into public.cafeterias (id, nombre, escuela, slug, pin_hash, activa) values
  ('00000000-0000-0000-0000-0000000000e1', 'Cafe Inactiva', 'Escuela N', 'cafe-inactiva-test',
   extensions.crypt('777777', extensions.gen_salt('bf')), false);
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', 'Escuela N', '777777'), 'pin_repetido', 'n: PIN igual al de una cafeteria inactiva');
-- Alta correcta: recorta espacios, slug sin acentos, PIN con hash y entrada con ese PIN.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', '  Cafetería Ñandú 1 ', ' Escuela N ', '555000'), 'n: alta correcta');
select pg_temp.chk((select count(*) from public.cafeterias where nombre = 'Cafetería Ñandú 1' and escuela = 'Escuela N') = 1,
  'n: nombre y escuela se guardan sin espacios sobrantes');
select pg_temp.chk((select slug from public.cafeterias where nombre = 'Cafetería Ñandú 1') = 'cafeteria-nandu-1-escuela-n',
  'n: slug sin acentos y con guiones');
select pg_temp.chk(public.entrar('555000')->>'cafeteria' = 'Cafetería Ñandú 1', 'n: la cafeteria nueva entra con su PIN');
select pg_temp.chk((select pin_hash <> '555000' and pin_hash like '$2%' from public.cafeterias where nombre = 'Cafetería Ñandú 1'),
  'n: el PIN se guarda con hash bcrypt, no en claro');
select set_config('qz.r_n2', public.crear_cafeteria('admin-prueba', 'Cafe N2', 'Escuela N', '555001')::text, true);
select pg_temp.chk(current_setting('qz.r_n2')::json->>'ok' = 'true' and current_setting('qz.r_n2') not like '%555001%',
  'n: otra alta correcta y la respuesta no incluye el PIN');
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N3', 'Escuela N', '555000'), 'pin_repetido',
  'n: no se puede repetir el PIN de una cafeteria recien creada');
-- Mismo nombre y escuela con otro PIN: el slug recibe sufijo; sin letras usa «cafeteria».
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafetería Ñandú 1', 'Escuela N', '555002'), 'n: mismo nombre y escuela con otro PIN');
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafeteria-nandu-1-escuela-n-2'), 'n: el slug repetido recibe el sufijo -2');
-- Espacios raros (tabulador, salto de linea, repetidos) se normalizan; acentos y letras variadas salen sin acento en el slug.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', E'Cafe\n  Tab\tUno', 'Escuela N', '555005'), 'n: nombre con tabulador, salto de linea y espacios repetidos');
select pg_temp.chk(exists (select 1 from public.cafeterias where nombre = 'Cafe Tab Uno' and slug = 'cafe-tab-uno-escuela-n'),
  'n: los espacios raros se colapsan a uno solo, en el nombre y en el slug');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Café Ça Ôpéra Müller', 'Escuela N', '555006'), 'n: nombre con acentos variados');
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafe-ca-opera-muller-escuela-n'),
  'n: el slug quita acentos de minusculas y mayusculas (a, e, i, o, u, u con dieresis, n, c)');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', '!!', '??', '555003'), 'n: nombre y escuela solo con simbolos');
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafeteria'), 'n: sin letras el slug es cafeteria');
-- anon puede llamarla (con la clave) y la nueva cafeteria aparece en metricas con ceros.
set local role anon;
select set_config('qz.anon_crear', public.crear_cafeteria('admin-prueba', 'Cafe Anon', 'Escuela N', '555004')->>'ok', true);
reset role;
select pg_temp.chk(current_setting('qz.anon_crear') = 'true', 'n: anon debe poder llamar crear_cafeteria con la clave correcta');
select pg_temp.esperar_fila(null::int, 'cafeteria-nandu-1-escuela-n', 0, 0, 0, 0);

-- ============ o) eliminar_cafeteria (baja desde el panel) ============
select set_config('qz.f1', (select count(*) from public.fallos_pin)::text, true);
select pg_temp.debe_err(public.eliminar_cafeteria('clave-mal', 'cafe-c'), 'clave_invalida', 'o: clave incorrecta');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.f1')::int + 1, 'o: una clave incorrecta se registra como fallo');
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafe-c'), 'o: con clave incorrecta no se borra nada');
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'no-hay-tal'), 'no_existe', 'o: slug inexistente');
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', null), 'no_existe', 'o: slug nulo');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.f1')::int + 1, 'o: un slug inexistente con clave correcta no registra fallos');
-- Con historial se niega y no borra; los conteos de la respuesta coinciden con la base.
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'cafe-a'), 'con_historial', 'o: A tiene historial');
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafe-a'), 'o: una cafeteria con historial no se borra');
select pg_temp.chk((public.eliminar_cafeteria('admin-prueba', 'cafe-a')->>'ventas')::int = (select count(*) from public.tokens where cafeteria_id = (select id from public.cafeterias where slug = 'cafe-a'))
  and (public.eliminar_cafeteria('admin-prueba', 'cafe-a')->>'reclamos')::int = (select count(*) from public.sellos where cafeteria_id = (select id from public.cafeterias where slug = 'cafe-a'))
  and (public.eliminar_cafeteria('admin-prueba', 'cafe-a')->>'canjes')::int = (select count(*) from public.canjes where cafeteria_id = (select id from public.cafeterias where slug = 'cafe-a')),
  'o: los conteos de con_historial coinciden con tokens, sellos y canjes de A');
-- Cada tipo de historial, por separado, impide la baja: una venta sin reclamar y un canje usado ahí.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Del Venta', 'Escuela O', '600001'), 'o: alta para probar la baja con una venta');
select pg_temp.debe_ok(public.crear_venta('600001'), 'o: venta en la cafeteria nueva');
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'cafe-del-venta-escuela-o'), 'con_historial', 'o: una venta sin reclamar ya cuenta como historial');
select pg_temp.chk((public.eliminar_cafeteria('admin-prueba', 'cafe-del-venta-escuela-o')->>'ventas')::int = 1, 'o: la respuesta cuenta la venta');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Del Canje', 'Escuela O', '600004'), 'o: alta para probar la baja con un canje');
with t as (insert into public.tarjetas default values returning id)
insert into public.canjes (tarjeta_id, cafeteria_id, codigo, usado_en)
  select t.id, c.id, '999999', now() from t, public.cafeterias c where c.slug = 'cafe-del-canje-escuela-o';
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'cafe-del-canje-escuela-o'), 'con_historial', 'o: un canje usado ahi cuenta como historial');
-- Sin historial: se borra, su PIN deja de entrar y el PIN y el slug quedan libres.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Del Libre', 'Escuela O', '600002'), 'o: alta de una cafeteria sin actividad');
select pg_temp.debe_ok(public.entrar('600002'), 'o: antes de borrarla su PIN entra');
select pg_temp.chk(public.eliminar_cafeteria('admin-prueba', 'cafe-del-libre-escuela-o')->>'cafeteria' = 'Cafe Del Libre', 'o: la baja devuelve el nombre');
select pg_temp.chk(not exists (select 1 from public.cafeterias where slug = 'cafe-del-libre-escuela-o'), 'o: la cafeteria borrada ya no existe');
select pg_temp.debe_err(public.entrar('600002'), 'pin_invalido', 'o: el PIN de una cafeteria borrada ya no entra');
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'cafe-del-libre-escuela-o'), 'no_existe', 'o: borrarla otra vez da no_existe');
select pg_temp.chk((select count(*) from public.cafeterias where slug in ('cafe-a', 'cafe-b', 'cafe-c')) = 3, 'o: borrar una cafeteria no toca a las demas');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Del Libre', 'Escuela O', '600002'), 'o: tras borrarla, el PIN y el slug quedan libres');
-- anon puede llamarla (con la clave).
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Del Anon', 'Escuela O', '600003'), 'o: alta para la baja hecha por anon');
set local role anon;
select set_config('qz.anon_elim', public.eliminar_cafeteria('admin-prueba', 'cafe-del-anon-escuela-o')->>'ok', true);
reset role;
select pg_temp.chk(current_setting('qz.anon_elim') = 'true', 'o: anon debe poder llamar eliminar_cafeteria con la clave correcta');
select pg_temp.chk(not exists (select 1 from public.cafeterias where slug = 'cafe-del-anon-escuela-o'), 'o: la baja hecha por anon borro la cafeteria');

-- ============ p) editar_cafeteria (edicion desde el panel) ============
-- Cafeterias propias de esta seccion (PIN 7000xx). Cafe A y B no se tocan.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Ed 1', 'Escuela P', '700001'), 'p: alta de Cafe Ed 1');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Ed 2', 'Escuela P', '700002'), 'p: alta de Cafe Ed 2');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Ed 3', 'Escuela P', '700003'), 'p: alta de Cafe Ed 3');
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Ed 4', 'Escuela P', '700004'), 'p: alta de Cafe Ed 4');

-- Clave incorrecta: error, un fallo mas y nada cambia.
select set_config('qz.p0', (select count(*) from public.fallos_pin)::text, true);
select pg_temp.debe_err(public.editar_cafeteria('clave-mal', 'cafe-ed-1-escuela-p', p_nombre => 'Nombre Malo'), 'clave_invalida', 'p: clave incorrecta');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.p0')::int + 1, 'p: una clave incorrecta se registra como fallo');
select pg_temp.chk((select nombre from public.cafeterias where slug = 'cafe-ed-1-escuela-p') = 'Cafe Ed 1', 'p: con clave incorrecta el nombre no cambia');

-- Slug inexistente o nulo: no_existe y sin fallo extra.
select set_config('qz.p0', (select count(*) from public.fallos_pin)::text, true);
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'no-hay-tal', p_nombre => 'Nombre X'), 'no_existe', 'p: slug inexistente');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', null, p_nombre => 'Nombre X'), 'no_existe', 'p: slug nulo');
select pg_temp.chk((select count(*) from public.fallos_pin) = current_setting('qz.p0')::int, 'p: slug inexistente o nulo con clave correcta no registra fallos');

-- Datos invalidos (nombre y escuela).
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_nombre => '   '), 'datos_invalidos', 'p: nombre vacio');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_nombre => 'X'), 'datos_invalidos', 'p: nombre de una letra');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_nombre => repeat('x', 81)), 'datos_invalidos', 'p: nombre de mas de 80');
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_escuela => ''), 'p: se puede quitar la escuela');
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_escuela => 'Escuela P'), 'p: y volver a ponerla');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_escuela => repeat('x', 41)), 'datos_invalidos', 'p: escuela de mas de 40');

-- Atomicidad: nombre valido + PIN invalido no cambia el nombre.
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_nombre => 'Nombre Atomico', p_pin => '12345'), 'pin_formato', 'p: atomicidad, PIN invalido');
select pg_temp.chk((select nombre from public.cafeterias where slug = 'cafe-ed-1-escuela-p') = 'Cafe Ed 1', 'p: atomicidad: un PIN invalido no cambia el nombre valido');
-- Atomicidad: tope valido + activa false + escuela invalida no cambia nada.
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_escuela => repeat('x', 41), p_activa => false, p_tope_hora => 5), 'datos_invalidos', 'p: atomicidad, escuela invalida');
select pg_temp.chk((select activa and tope_hora = 30 and escuela = 'Escuela P' from public.cafeterias where slug = 'cafe-ed-1-escuela-p'),
  'p: atomicidad: ni tope, ni activa, ni escuela cambian si otro dato es invalido');

-- Normalizacion de espacios y saltos de linea en nombre y escuela.
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_nombre => E'  Cafe\n\tEd   Uno  ', p_escuela => E'Escuela\n\t  Pe  '), 'p: nombre y escuela con espacios, tabuladores y saltos de linea');
select pg_temp.chk((select nombre || '|' || escuela from public.cafeterias where slug = 'cafe-ed-1-escuela-p') = 'Cafe Ed Uno|Escuela Pe',
  'p: nombre y escuela se normalizan a espacios simples y sin bordes');

-- PIN con formato invalido.
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '70000'), 'pin_formato', 'p: PIN de 5 digitos');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '7000011'), 'pin_formato', 'p: PIN de 7 digitos');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => 'abcdef'), 'pin_formato', 'p: PIN con letras');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => E'700005\n'), 'pin_formato', 'p: PIN con salto de linea final');

-- PIN repetido: de una cafeteria activa (Cafe B) y de una inactiva (Cafe Ed 3).
update public.cafeterias set activa = false where slug = 'cafe-ed-3-escuela-p';
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '222222'), 'pin_repetido', 'p: PIN igual al de otra cafeteria activa');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '700003'), 'pin_repetido', 'p: PIN igual al de una cafeteria inactiva');

-- PIN igual al propio: ok sin cambio de PIN.
select set_config('qz.e1', public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '700001')::text, true);
select pg_temp.chk(current_setting('qz.e1')::json->>'ok' = 'true' and current_setting('qz.e1')::json->>'pin_cambiado' = 'false',
  'p: el mismo PIN propio es ok con pin_cambiado=false | respuesta: ' || current_setting('qz.e1'));

-- Cambio de PIN: el viejo deja de entrar, el nuevo entra; la respuesta no trae el PIN ni su hash.
select set_config('qz.e2', public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_pin => '700006')::text, true);
select pg_temp.chk(current_setting('qz.e2')::json->>'ok' = 'true' and current_setting('qz.e2')::json->>'pin_cambiado' = 'true',
  'p: cambio de PIN es ok con pin_cambiado=true | respuesta: ' || current_setting('qz.e2'));
select pg_temp.chk(current_setting('qz.e2') not like '%700006%' and current_setting('qz.e2') not like '%$2%',
  'p: la respuesta no incluye el PIN ni su hash');
select pg_temp.debe_err(public.entrar('700001'), 'pin_invalido', 'p: el PIN anterior ya no entra');
select pg_temp.chk(public.entrar('700006')->>'cafeteria' = 'Cafe Ed Uno', 'p: el PIN nuevo entra');

-- Activa: false impide entrar y vender; true vuelve a permitirlo.
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_activa => false), 'p: desactivar la cafeteria');
select pg_temp.debe_err(public.entrar('700006'), 'pin_invalido', 'p: cafeteria desactivada no entra');
select pg_temp.debe_err(public.crear_venta('700006'), 'pin_invalido', 'p: cafeteria desactivada no crea venta');
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_activa => true), 'p: reactivar la cafeteria');
select pg_temp.debe_ok(public.entrar('700006'), 'p: al reactivar vuelve a entrar');

-- Personalización: tipo y logo salen en entrar; el valor por defecto es «Cafetería» sin logo.
select pg_temp.chk(public.entrar('700006')->>'tipo' = 'Cafetería' and public.entrar('700006')->'logo' is not null
  and (public.entrar('700006')->>'logo') is null, 'q: por defecto tipo=Cafetería y logo nulo');
update public.cafeterias set tipo = 'Bar', logo = 'img/negocios/x.png' where slug = 'cafe-ed-1-escuela-p';
select pg_temp.chk(public.entrar('700006')->>'tipo' = 'Bar' and public.entrar('700006')->>'logo' = 'img/negocios/x.png', 'q: entrar devuelve tipo y logo');
-- mis_metricas: solo con el PIN del propio negocio, sin la clave admin.
select pg_temp.debe_ok(public.mis_metricas('700006', 7), 'q: mis_metricas con PIN valido');
select pg_temp.chk((public.mis_metricas('700006')->>'cafeteria') = 'Cafe Ed Uno' and (public.mis_metricas('700006')->>'ventas')::int = 0, 'q: mis_metricas devuelve su nombre y conteos');
select pg_temp.debe_err(public.mis_metricas('999999'), 'pin_invalido', 'q: mis_metricas con PIN malo');

-- ============ r) Programas propios, distribuidor, configuración y cuenta de control ============
select pg_temp.debe_err(public.crear_venta('700006', true), 'no_distribuidor', 'r: sin ser distribuidor no genera QR Quetzalitos');
select set_config('qz.rp', (select id::text from public.cafeterias where slug = 'cafe-ed-1-escuela-p'), true);
select set_config('qz.r1', public.crear_venta('700006')::text, true);
select pg_temp.chk(current_setting('qz.r1')::json->>'programa' = current_setting('qz.rp'), 'r: el QR por defecto es del programa propio');
select set_config('qz.rt', pg_temp.reclamar_ok(current_setting('qz.r1')::json->>'codigo', null, 'r: reclamo del programa propio'), true);
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->>'sellos')::int = 1, 'r: el sello cuenta en el programa propio');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid)->>'sellos')::int = 0, 'r: y no cuenta en Quetzalitos');
select pg_temp.chk(public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->'config'->>'nombre' = 'Cafe Ed Uno', 'r: la tarjeta trae la config del negocio');
select pg_temp.debe_err(public.tarjeta(current_setting('qz.rt')::uuid, '00000000-0000-0000-0000-0000000000ff'), 'tarjeta_invalida', 'r: un programa que no existe');

-- El enfriamiento de 10 minutos es por programa.
select pg_temp.debe_ok(public.set_distribuidor('admin-prueba', 'cafe-ed-1-escuela-p', true), 'r: activar distribuidor');
select pg_temp.debe_ok(public.reclamar(public.crear_venta('700006', true)->>'codigo', current_setting('qz.rt')::uuid), 'r: sello Quetzalitos justo despues del propio');
select pg_temp.debe_err(public.reclamar(public.crear_venta('700006')->>'codigo', current_setting('qz.rt')::uuid), 'sello_reciente', 'r: dos sellos propios seguidos');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid)->>'sellos')::int = 1, 'r: Quetzalitos suma aparte');

-- guardar_config: valida todo antes de escribir.
select pg_temp.debe_err(public.guardar_config('700006', p_color => 'rojo'), 'config_invalida', 'r: color invalido');
select pg_temp.debe_err(public.guardar_config('700006', p_meta => 0), 'config_invalida', 'r: meta 0');
select pg_temp.debe_err(public.guardar_config('700006', p_meta => 51), 'config_invalida', 'r: meta 51');
select pg_temp.debe_err(public.guardar_config('700006', p_logo => 'javascript:alert(1)'), 'config_invalida', 'r: logo javascript:');
select pg_temp.debe_err(public.guardar_config('700006', p_logo => 'https://a.com/x.png"onerror='), 'config_invalida', 'r: logo con comillas');
select pg_temp.debe_err(public.guardar_config('700006', p_premio => ''), 'config_invalida', 'r: premio vacio');
select pg_temp.chk((public.entrar('700006')->>'meta')::int = 6, 'r: un intento invalido no cambia nada');
select pg_temp.debe_err(public.guardar_config('999999', p_meta => 3), 'pin_invalido', 'r: guardar_config con PIN malo');
select pg_temp.debe_ok(public.guardar_config('700006', p_meta => 2, p_premio => '  Un café   gratis ', p_unidad => 'visitas',
  p_mensaje => 'Gracias', p_color => '#1F5BD6', p_logo => 'https://ejemplo.com/logo.png'), 'r: guardar la config');
select pg_temp.chk(public.entrar('700006')->>'premio' = 'Un café gratis' and public.entrar('700006')->>'unidad' = 'visitas'
  and public.entrar('700006')->>'color' = '#1F5BD6' and (public.entrar('700006')->>'meta')::int = 2, 'r: entrar devuelve la config guardada');
select pg_temp.debe_ok(public.guardar_config('700006', p_logo => '', p_mensaje => '', p_color => ''), 'r: vaciar logo, mensaje y color');
select pg_temp.chk(public.entrar('700006')->>'logo' is null and public.entrar('700006')->>'color' is null, 'r: logo y color vacios quedan en null');

-- Premio propio con meta 2: solo lo canjea su dueño y cambiar la meta después no altera el saldo.
update public.sellos set creado_en = now() - interval '11 minutes' where tarjeta_id = current_setting('qz.rt')::uuid;
select pg_temp.debe_ok(public.reclamar(public.crear_venta('700006')->>'codigo', current_setting('qz.rt')::uuid), 'r: segundo sello propio');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->>'premio_listo')::boolean, 'r: con meta 2 el premio propio esta listo');
select set_config('qz.rc', public.pedir_canje(current_setting('qz.rt')::uuid, current_setting('qz.rp'))::text, true);
select pg_temp.chk(current_setting('qz.rc')::json->>'ok' = 'true', 'r: pedir_canje del programa propio | ' || current_setting('qz.rc'));
select pg_temp.debe_err(public.canjear('700006', 'xxxxxx'), 'canje_invalido', 'r: codigo de canje inexistente');
select pg_temp.debe_err(public.canjear('700004', current_setting('qz.rc')::json->>'codigo'), 'canje_invalido', 'r: otro negocio no canjea un premio propio ajeno');
select set_config('qz.rk', public.canjear('700006', current_setting('qz.rc')::json->>'codigo')::text, true);
select pg_temp.chk(current_setting('qz.rk')::json->>'ok' = 'true' and current_setting('qz.rk')::json->>'premio' = 'Un café gratis', 'r: el dueño canjea y recibe el premio | ' || current_setting('qz.rk'));
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->>'sellos')::int = 0, 'r: tras el canje el saldo propio queda en 0');
select pg_temp.debe_ok(public.guardar_config('700006', p_meta => 5), 'r: subir la meta despues del canje');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->>'sellos')::int = 0, 'r: cambiar la meta no vuelve negativo el saldo');

-- Un premio Quetzalitos solo lo canjea un distribuidor.
insert into public.canjes (tarjeta_id, codigo, programa, meta) values (current_setting('qz.rt')::uuid, '424242', 'q', 6);
select pg_temp.debe_ok(public.set_distribuidor('admin-prueba', 'cafe-ed-1-escuela-p', false), 'r: quitar distribuidor');
select pg_temp.debe_err(public.canjear('700006', '424242'), 'no_distribuidor', 'r: sin ser distribuidor no canjea premios Quetzalitos');
select pg_temp.debe_err(public.crear_venta('700006', true), 'no_distribuidor', 'r: sin ser distribuidor ya no genera QR Quetzalitos');
delete from public.canjes where codigo = '424242';
select pg_temp.debe_err(public.set_distribuidor('mala', 'cafe-a', true), 'clave_invalida', 'r: set_distribuidor con clave mala');
select pg_temp.debe_err(public.set_distribuidor('admin-prueba', 'no-hay', true), 'no_existe', 'r: set_distribuidor de una cafeteria inexistente');

-- guardar_tema: lista cerrada, valida todo y reemplaza el tema entero.
select pg_temp.debe_ok(public.guardar_tema('700006', '{"acento":"#E4007C","fondo":"#0A2E22","fuente_titulo":"georgia","emoji_venta":"🍺","fondo_img":"https://ejemplo.com/f.jpg","emoji_canje":""}'::json), 's: guardar tema valido');
select pg_temp.chk(public.entrar('700006')->'tema'->>'acento' = '#E4007C' and public.entrar('700006')->'tema'->>'emoji_venta' = '🍺'
  and not ((public.entrar('700006')->'tema')::jsonb ? 'emoji_canje'), 's: entrar devuelve el tema y omite lo vacio');
select pg_temp.debe_err(public.guardar_tema('700006', '{"acento":"rojo"}'::json), 'tema_invalido', 's: color invalido');
select pg_temp.debe_err(public.guardar_tema('700006', '{"fuente_texto":"comic"}'::json), 'tema_invalido', 's: fuente fuera de la lista');
select pg_temp.debe_err(public.guardar_tema('700006', '{"otra":"x"}'::json), 'tema_invalido', 's: clave desconocida');
select pg_temp.debe_err(public.guardar_tema('700006', '{"emoji_venta":"<b>"}'::json), 'tema_invalido', 's: emoji con marcado');
select pg_temp.debe_err(public.guardar_tema('700006', '{"fondo_img":"javascript:alert(1)"}'::json), 'tema_invalido', 's: imagen javascript:');
select pg_temp.debe_err(public.guardar_tema('700006', '{"fondo_img":"https://a.com/x.png\")"}'::json), 'tema_invalido', 's: imagen con comillas o parentesis');
select pg_temp.debe_err(public.guardar_tema('700006', '[1]'::json), 'tema_invalido', 's: el tema debe ser un objeto');
select pg_temp.debe_err(public.guardar_tema('700006', '{"acento":5}'::json), 'tema_invalido', 's: valores que no son texto');
select pg_temp.chk(public.entrar('700006')->'tema'->>'acento' = '#E4007C', 's: un tema invalido no cambia el guardado');
select pg_temp.debe_err(public.guardar_tema('999999', '{}'::json), 'pin_invalido', 's: guardar_tema con PIN malo');
select pg_temp.debe_ok(public.guardar_tema('700006', '{}'::json), 's: restablecer el tema');
select pg_temp.chk(public.entrar('700006')->'tema' is null or (public.entrar('700006')->>'tema') is null, 's: tema restablecido en null');

-- t) Cancelar venta y foto de perfil.
select set_config('qz.tv', public.crear_venta('700006')::text, true);
select pg_temp.chk(public.mis_metricas('700006')->>'ventas' is not null, 't: base');
select set_config('qz.tn', (public.mis_metricas('700006')->>'ventas'), true);
select pg_temp.debe_ok(public.cancelar_venta('700006', current_setting('qz.tv')::json->>'codigo'), 't: cancelar una venta sin escanear');
select pg_temp.debe_ok(public.cancelar_venta('700006', current_setting('qz.tv')::json->>'codigo'), 't: cancelar dos veces es idempotente');
select pg_temp.chk((public.mis_metricas('700006')->>'ventas') = (current_setting('qz.tn')::int - 1)::text, 't: la venta cancelada ya no cuenta');
select pg_temp.debe_err(public.reclamar(current_setting('qz.tv')::json->>'codigo', null), 'token_cancelado', 't: un QR cancelado no se puede reclamar');
select pg_temp.debe_err(public.cancelar_venta('700004', current_setting('qz.tv')::json->>'codigo'), 'token_invalido', 't: otro negocio no puede cancelar mi venta');
select pg_temp.debe_err(public.cancelar_venta('999999', 'x'), 'pin_invalido', 't: cancelar con PIN malo');
select set_config('qz.tu', public.crear_venta('700006')::json->>'codigo', true);
select pg_temp.debe_ok(public.reclamar(current_setting('qz.tu'), null), 't: reclamo normal');
select pg_temp.debe_err(public.cancelar_venta('700006', current_setting('qz.tu')), 'token_usado', 't: no se cancela un QR ya escaneado');
select pg_temp.debe_ok(public.guardar_config('700006', p_logo => 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ=='), 't: foto de perfil como data URL');
select pg_temp.chk(public.entrar('700006')->>'logo' like 'data:image/jpeg;base64,%', 't: entrar devuelve la foto');
select pg_temp.debe_err(public.guardar_config('700006', p_logo => 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4='), 'config_invalida', 't: SVG no se acepta como foto');
select pg_temp.debe_err(public.guardar_config('700006', p_logo => 'data:text/html;base64,PGI+'), 'config_invalida', 't: html no se acepta como foto');
select pg_temp.debe_err(public.guardar_config('700006', p_logo => 'data:image/png;base64,' || repeat('A', 60000)), 'config_invalida', 't: foto demasiado grande');
select pg_temp.debe_ok(public.guardar_config('700006', p_logo => ''), 't: quitar la foto');

-- u) Configuración editable de Quetzalitos (solo con la clave admin) y fondo con foto.
select pg_temp.debe_err(public.quetzalitos_config('mala'), 'clave_invalida', 'u: clave mala');
select pg_temp.chk(public.quetzalitos_config('admin-prueba')->'config'->>'premio' = 'Un postre gratis', 'u: sin parametros devuelve lo vigente (premio por defecto)');
select pg_temp.debe_err(public.quetzalitos_config('admin-prueba', p_meta => 0), 'config_invalida', 'u: meta 0');
select pg_temp.debe_err(public.quetzalitos_config('admin-prueba', p_premio => ''), 'config_invalida', 'u: premio vacio');
select pg_temp.debe_ok(public.quetzalitos_config('admin-prueba', p_meta => 8, p_premio => ' Un   postre de regalo ', p_unidad => 'quetzales', p_mensaje => 'Gracias'), 'u: guardar la config');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'meta')::int = 8
  and public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'premio' = 'Un postre de regalo'
  and public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'unidad' = 'quetzales'
  and public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'mensaje' = 'Gracias', 'u: la tarjeta Quetzalitos refleja la config');
select pg_temp.debe_ok(public.quetzalitos_config('admin-prueba', p_mensaje => ''), 'u: borrar el mensaje');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'mensaje') is null, 'u: mensaje borrado');
select pg_temp.debe_ok(public.quetzalitos_config('admin-prueba', p_meta => 6, p_premio => 'Un postre gratis', p_unidad => 'sellos'), 'u: restaurar valores originales');
select pg_temp.debe_ok(public.guardar_tema('700006', json_build_object('fondo_img', 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ==')), 'u: fondo con foto');
select pg_temp.debe_err(public.guardar_tema('700006', json_build_object('fondo_img', 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=')), 'tema_invalido', 'u: el fondo no acepta SVG');
select pg_temp.debe_err(public.guardar_tema('700006', json_build_object('fondo_img', 'data:image/png;base64,' || repeat('A', 150000))), 'tema_invalido', 'u: fondo demasiado grande');
select pg_temp.debe_ok(public.guardar_tema('700006', '{}'::json), 'u: limpiar el tema');

-- v) El emoji de sello y el tema viajan en la config del programa del negocio (lo que lee la tarjeta del cliente).
select pg_temp.debe_ok(public.guardar_tema('700006', '{"emoji_sello":"🎲","acento":"#B94030"}'::json), 'v: guardar emoji de sello');
select pg_temp.chk(public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->'config'->>'sello' = '🎲'
  and public.tarjeta(current_setting('qz.rt')::uuid, current_setting('qz.rp'))->'config'->'tema'->>'acento' = '#B94030', 'v: la config trae sello y tema');
select pg_temp.chk((public.tarjeta(current_setting('qz.rt')::uuid)->'config'->>'sello') is null, 'v: Quetzalitos no lleva sello propio');
select pg_temp.debe_err(public.guardar_tema('700006', '{"emoji_sello":"<img>"}'::json), 'tema_invalido', 'v: emoji de sello con marcado');
select pg_temp.debe_ok(public.guardar_tema('700006', '{}'::json), 'v: limpiar');

-- w) Mensualidad: fecha de alta, vencimiento, registrar pago y banner (dias_para_vencer).
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Cafe Mensual', 'Escuela M', '810001'), 'w: alta para probar la mensualidad');
select pg_temp.chk((select creada_en from public.cafeterias where slug = 'cafe-mensual-escuela-m') is not null, 'w: la alta guarda la fecha de creacion');
select pg_temp.chk((public.entrar('810001')->>'dias_para_vencer')::int between 27 and 31, 'w: la primera mensualidad vence en ~1 mes | ' || (public.entrar('810001')->>'dias_para_vencer'));
select pg_temp.chk(public.entrar('810001')->>'vence_en' is not null and public.entrar('810001')->>'creada_en' is not null, 'w: entrar trae creada_en y vence_en');
select pg_temp.chk((select (f->>'dias_para_vencer')::int between 27 and 31 and f->>'creada_en' is not null
                     from json_array_elements(public.metricas('admin-prueba')->'filas') f where f->>'slug' = 'cafe-mensual-escuela-m'), 'w: metricas trae creada_en, vence_en y dias_para_vencer');
select pg_temp.debe_err(public.set_vencimiento('mala', 'cafe-mensual-escuela-m', p_meses => 1), 'clave_invalida', 'w: set_vencimiento con clave mala');
select pg_temp.debe_err(public.set_vencimiento('admin-prueba', 'no-hay', p_meses => 1), 'no_existe', 'w: set_vencimiento de un negocio inexistente');
select pg_temp.debe_err(public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_meses => 0), 'fecha_invalida', 'w: 0 meses');
select pg_temp.debe_err(public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_meses => 25), 'fecha_invalida', 'w: 25 meses');
select pg_temp.debe_err(public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_vence => current_date + 4000), 'fecha_invalida', 'w: fecha muy lejana');
select pg_temp.debe_ok(public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_vence => public._hoy() + 2), 'w: fijar el vencimiento en 2 dias');
select pg_temp.chk((public.entrar('810001')->>'dias_para_vencer')::int = 2, 'w: faltan 2 dias para vencer');
select pg_temp.debe_ok(public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_vence => public._hoy() - 5), 'w: fijar un vencimiento pasado');
select pg_temp.chk((public.entrar('810001')->>'dias_para_vencer')::int = -5, 'w: vencida hace 5 dias (negativo)');
select pg_temp.chk((public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_meses => 1)->>'vence_en')::date = (public._hoy() + interval '1 month')::date,
  'w: registrar pago vencido suma el mes desde hoy');
select pg_temp.chk((public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m', p_meses => 1)->>'vence_en')::date = (public._hoy() + interval '2 months')::date,
  'w: registrar pago adelantado suma el mes desde el vencimiento actual');
select pg_temp.chk((public.set_vencimiento('admin-prueba', 'cafe-mensual-escuela-m')->>'vence_en') is null and (public.entrar('810001')->>'dias_para_vencer') is null,
  'w: sin parametros quita el seguimiento');
select pg_temp.chk((public.entrar('800001')->>'dias_para_vencer') is null, 'w: la cuenta de control no tiene vencimiento');

-- x) estadisticas: periodo a elegir, horas, dias de la semana y serie diaria.
select pg_temp.debe_err(public.estadisticas('999999'), 'pin_invalido', 'x: PIN malo');
select pg_temp.debe_err(public.estadisticas('800001'), 'pin_invalido', 'x: la cuenta de control no tiene estadisticas');
select pg_temp.debe_err(public.estadisticas('700006', current_date, current_date - 3), 'rango_invalido', 'x: fin anterior al inicio');
select pg_temp.debe_err(public.estadisticas('700006', current_date - 400, current_date), 'rango_invalido', 'x: mas de 366 dias');
select set_config('qz.es', public.estadisticas('700006')::text, true);
select pg_temp.debe_ok(current_setting('qz.es')::json, 'x: estadisticas con el periodo por defecto');
select pg_temp.chk(json_array_length(current_setting('qz.es')::json->'por_hora') = 24 and json_array_length(current_setting('qz.es')::json->'por_dia_semana') = 7,
  'x: 24 horas y 7 dias');
select pg_temp.chk(json_array_length(current_setting('qz.es')::json->'serie') = (current_setting('qz.es')::json->>'dias')::int, 'x: la serie trae un punto por dia');
select pg_temp.chk((current_setting('qz.es')::json->'resumen'->>'ventas')::int >= 1, 'x: cuenta las ventas del negocio');
select pg_temp.chk((select sum((h->>'ventas')::int) from json_array_elements(current_setting('qz.es')::json->'por_hora') h) = (current_setting('qz.es')::json->'resumen'->>'ventas')::int,
  'x: la suma por hora coincide con las ventas');
select pg_temp.chk((select sum((d->>'ventas')::int) from json_array_elements(current_setting('qz.es')::json->'por_dia_semana') d) = (current_setting('qz.es')::json->'resumen'->>'ventas')::int,
  'x: la suma por dia de la semana coincide con las ventas');
select pg_temp.chk((select sum((d->>'reclamos')::int) from json_array_elements(current_setting('qz.es')::json->'serie') d) = (current_setting('qz.es')::json->'resumen'->>'reclamos')::int,
  'x: la suma de la serie coincide con los reclamos');
select pg_temp.chk((current_setting('qz.es')::json->'resumen'->>'clientes')::int >= (current_setting('qz.es')::json->'resumen'->>'nuevos')::int
  and (current_setting('qz.es')::json->'resumen'->>'repiten')::int <= (current_setting('qz.es')::json->'resumen'->>'clientes')::int, 'x: clientes >= nuevos y repiten <= clientes');
select pg_temp.chk((public.estadisticas('700006', public._hoy() - 10, public._hoy() - 5)->'resumen'->>'ventas')::int = 0, 'x: un periodo sin actividad da ceros');
select pg_temp.chk((public.estadisticas('700006', public._hoy(), public._hoy())->>'dias')::int = 1, 'x: un solo dia (hoy)');

-- Cuenta de control: entra como una cafeteria, marca admin y no sale en métricas ni se puede volver distribuidor.
select pg_temp.debe_ok(public.crear_cafeteria('admin-prueba', 'Control Quetzalitos', 'Quetzalitos', '800001'), 'r: alta de la cuenta de control');
update public.cafeterias set super_admin = true where slug = 'control-quetzalitos-quetzalitos';
select pg_temp.chk(public.entrar('800001')->>'admin' = 'true' and public.entrar('700006')->>'admin' = 'false', 'r: entrar marca solo la cuenta de control');
select pg_temp.chk(not exists (select 1 from json_array_elements(public.metricas('admin-prueba')->'filas') f
  where f->>'slug' = 'control-quetzalitos-quetzalitos'), 'r: la cuenta de control no sale en metricas');
select pg_temp.debe_err(public.set_distribuidor('admin-prueba', 'control-quetzalitos-quetzalitos', true), 'no_existe', 'r: la cuenta de control no es distribuidora');
select pg_temp.debe_err(public.crear_venta('800001'), 'pin_invalido', 'r: la cuenta de control no genera QR');
select pg_temp.debe_err(public.canjear('800001', '123456'), 'pin_invalido', 'r: la cuenta de control no canjea');
select pg_temp.debe_err(public.guardar_tema('800001', '{}'::json), 'pin_invalido', 'r: la cuenta de control no edita tema');
select pg_temp.chk(public.entrar('800001')->>'admin' = 'true', 'r: la cuenta de control si entra');

-- Tope por hora: 0, -5 y 1001 son invalidos; 1 y 1000 son validos y quedan guardados.
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_tope_hora => 0), 'tope_invalido', 'p: tope 0');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_tope_hora => -5), 'tope_invalido', 'p: tope -5');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_tope_hora => 1001), 'tope_invalido', 'p: tope 1001');
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_tope_hora => 1), 'p: tope 1 es valido');
select pg_temp.chk((select tope_hora from public.cafeterias where slug = 'cafe-ed-1-escuela-p') = 1, 'p: tope 1 queda guardado');
select pg_temp.debe_ok(public.editar_cafeteria('admin-prueba', 'cafe-ed-1-escuela-p', p_tope_hora => 1000), 'p: tope 1000 es valido');
select pg_temp.chk((select tope_hora from public.cafeterias where slug = 'cafe-ed-1-escuela-p') = 1000, 'p: tope 1000 queda guardado');

-- anon puede llamarla (con la clave correcta).
set local role anon;
select set_config('qz.anon_edit', public.editar_cafeteria('admin-prueba', 'cafe-ed-2-escuela-p', p_nombre => 'Cafe Ed Anon')->>'ok', true);
reset role;
select pg_temp.chk(current_setting('qz.anon_edit') = 'true', 'p: anon debe poder llamar editar_cafeteria con la clave correcta');
select pg_temp.chk((select nombre from public.cafeterias where slug = 'cafe-ed-2-escuela-p') = 'Cafe Ed Anon', 'p: la edicion hecha por anon se guarda');

-- Renombrar conserva el slug y el historial: la venta sigue contada bajo el nombre nuevo.
select pg_temp.debe_ok(public.set_distribuidor('admin-prueba', 'cafe-ed-4-escuela-p', true), 'p: activar distribuidor para la venta de prueba');
select pg_temp.nueva_venta('700004');
select set_config('qz.e4', public.editar_cafeteria('admin-prueba', 'cafe-ed-4-escuela-p', p_nombre => 'Cafe Renombrada')::text, true);
select pg_temp.chk(current_setting('qz.e4')::json->>'slug' = 'cafe-ed-4-escuela-p' and current_setting('qz.e4')::json->>'cafeteria' = 'Cafe Renombrada',
  'p: la respuesta trae el nombre nuevo y el slug original | respuesta: ' || current_setting('qz.e4'));
select pg_temp.chk(exists (select 1 from public.cafeterias where slug = 'cafe-ed-4-escuela-p' and nombre = 'Cafe Renombrada'), 'p: el slug no cambia al renombrar');
select pg_temp.chk(exists (select 1 from json_array_elements(public.metricas('admin-prueba', null::int)->'filas') e where e::text like '%Cafe Renombrada%'),
  'p: metricas muestra el nombre nuevo');
select pg_temp.esperar_fila(null::int, 'cafe-ed-4-escuela-p', 1, 0, 0, 0);

-- metricas devuelve activa y tope_hora por cafeteria.
select pg_temp.chk(exists (select 1 from json_array_elements(public.metricas('admin-prueba', null::int)->'filas') e
  where e->>'slug' = 'cafe-ed-4-escuela-p' and (e->>'activa')::boolean = true and (e->>'tope_hora')::int = 30),
  'p: metricas: cafeteria activa con tope 30 por defecto');
select pg_temp.chk(exists (select 1 from json_array_elements(public.metricas('admin-prueba', null::int)->'filas') e
  where e->>'slug' = 'cafe-ed-3-escuela-p' and (e->>'activa')::boolean = false and (e->>'tope_hora')::int = 30),
  'p: metricas: cafeteria desactivada con activa=false');
select pg_temp.chk(exists (select 1 from json_array_elements(public.metricas('admin-prueba', null::int)->'filas') e
  where e->>'slug' = 'cafe-ed-1-escuela-p' and (e->>'activa')::boolean = true and (e->>'tope_hora')::int = 1000),
  'p: metricas: tope_hora refleja el valor editado');

-- ============ n) NFC en claro (UID + contador + CMAC) ============
create function pg_temp.cmac_sun(p_llave text, p_uid text, p_ctr text)
returns text language plpgsql as $$
declare ctr bytea := decode(p_ctr, 'hex');
  ses bytea := public._cmac(decode(p_llave, 'hex'), '\x3cc300010080'::bytea || decode(p_uid, 'hex')
    || substring(ctr from 3 for 1) || substring(ctr from 2 for 1) || substring(ctr from 1 for 1));
  mac bytea := public._cmac(ses, ''::bytea);
  corto text := ''; i int;
begin
  for i in 0..7 loop corto := corto || lpad(to_hex(get_byte(mac, i * 2 + 1)), 2, '0'); end loop;
  return corto;
end $$;

create function pg_temp.tap(p_llave text, p_uid text, p_ctr text, p_tarjeta uuid)
returns json language plpgsql as $$
begin
  return public.reclamar_nfc(p_uid, p_ctr, pg_temp.cmac_sun(p_llave, p_uid, p_ctr), p_tarjeta);
end $$;

select pg_temp.debe_err(public.crear_etiqueta('admin-prueba', 'no-existe'), 'no_existe', 'n: crear_etiqueta de cafeteria inexistente');
select pg_temp.debe_err(public.crear_etiqueta('admin-prueba', 'cafe-a', null, 'zz'), 'nfc_invalido', 'n: uid con formato malo');
select set_config('qz.llave', public.crear_etiqueta('admin-prueba', 'cafe-a', null, '04DE5F1EACC040')->>'llave', true);
select pg_temp.chk(length(current_setting('qz.llave')) = 32, 'n: crear_etiqueta devuelve llave de 16 bytes en hex');
select pg_temp.debe_err(public.crear_etiqueta('admin-prueba', 'cafe-a', null, '04DE5F1EACC040'), 'uid_repetido', 'n: mismo uid no se da de alta dos veces');
select set_config('qz.nt1', gen_random_uuid()::text, true), set_config('qz.nt2', gen_random_uuid()::text, true);
select pg_temp.chk(public.llave_de_uid('admin-prueba', '04DE5F1EACC040')->>'llave' = current_setting('qz.llave'), 'n: llave_de_uid devuelve la llave');
select pg_temp.debe_err(public.llave_de_uid('admin-prueba', '000000000000AA'), 'no_existe', 'n: llave_de_uid de uid desconocido');

select pg_temp.debe_err(public.reclamar_nfc('00', '000001', '0000000000000000', null), 'nfc_invalido', 'n: formato malo');
select pg_temp.debe_err(public.reclamar_nfc('04DE5F1EACC040', '000001', '0000000000000000', null), 'nfc_invalido', 'n: cmac falso');
select pg_temp.debe_ok(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '010000', current_setting('qz.nt1')::uuid), 'n: primer toque suma sello');
select pg_temp.chk((pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '010000', current_setting('qz.nt1')::uuid))->>'repetido' = 'true', 'n: mismo enlace y misma tarjeta es repetido');
select pg_temp.chk((pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '010000', current_setting('qz.nt1')::uuid))->>'sellos' = '1', 'n: el repetido no suma otro sello');
select pg_temp.debe_err(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '010000', current_setting('qz.nt2')::uuid), 'nfc_usado', 'n: enlace usado por otra tarjeta');
select pg_temp.debe_err(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '050000', current_setting('qz.nt1')::uuid), 'sello_reciente', 'n: enfriamiento de 15 min');
update public.sellos set creado_en = now() - interval '20 minutes' where tarjeta_id = current_setting('qz.nt1')::uuid;
select pg_temp.debe_err(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '030000', current_setting('qz.nt1')::uuid), 'nfc_usado', 'n: contador menor al último visto');
select pg_temp.debe_ok(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '060000', current_setting('qz.nt1')::uuid), 'n: pasado el enfriamiento suma sello');
update public.sellos set creado_en = now() - interval '20 minutes' where tarjeta_id = current_setting('qz.nt1')::uuid;
select pg_temp.debe_ok(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '070000', current_setting('qz.nt1')::uuid), 'n: tercer sello NFC del día');
update public.sellos set creado_en = now() - interval '20 minutes' where tarjeta_id = current_setting('qz.nt1')::uuid;
select pg_temp.debe_ok(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '080000', current_setting('qz.nt1')::uuid), 'n: cuarto sello NFC del día');
update public.sellos set creado_en = now() - interval '20 minutes' where tarjeta_id = current_setting('qz.nt1')::uuid;
select pg_temp.debe_err(pg_temp.tap(current_setting('qz.llave'), '04DE5F1EACC040', '090000', current_setting('qz.nt1')::uuid), 'tope_dia', 'n: quinto sello NFC del día');

-- Etiqueta de cafe-b creada sin UID: el primer toque la liga a su UID y suma solo en cafe-b.
select set_config('qz.llave_b', public.crear_etiqueta('admin-prueba', 'cafe-b')->>'llave', true);
select set_config('qz.nt3', gen_random_uuid()::text, true);
select pg_temp.debe_ok(pg_temp.tap(current_setting('qz.llave_b'), '0A0B0C0D0E0F10', '010000', current_setting('qz.nt3')::uuid), 'n2: primer toque de etiqueta sin UID');
select pg_temp.chk((select count(*) from public.sellos s join public.cafeterias c on c.id = s.cafeteria_id
  where s.tarjeta_id = current_setting('qz.nt3')::uuid and c.slug = 'cafe-b') = 1
  and (select count(*) from public.sellos where tarjeta_id = current_setting('qz.nt3')::uuid) = 1,
  'n2: el sello cae solo en cafe-b');
select pg_temp.chk(public.llave_de_uid('admin-prueba', '0A0B0C0D0E0F10')->>'llave' = current_setting('qz.llave_b'), 'n2: tras el primer toque, la etiqueta queda ligada a su UID');
select pg_temp.chk((select count(*) from public.sellos s join public.cafeterias c on c.id = s.cafeteria_id
  where s.etiqueta_id is not null and c.slug = 'cafe-a') = 4, 'n2: cafe-a conserva solo sus sellos NFC');

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
select set_config('qz.ncaf', (select count(*) from public.cafeterias)::text, true);
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe Z', 'Escuela Z', '666000'), 'bloqueado', 'h: crear_cafeteria con clave correcta tras 30 fallos');
select pg_temp.chk((select count(*) from public.cafeterias)::text = current_setting('qz.ncaf'), 'h: una crear_cafeteria bloqueada no debe crear cafeteria');
select pg_temp.debe_err(public.eliminar_cafeteria('admin-prueba', 'cafe-c'), 'bloqueado', 'h: eliminar_cafeteria con clave correcta tras 30 fallos');
select pg_temp.chk((select count(*) from public.cafeterias)::text = current_setting('qz.ncaf'), 'h: una eliminar_cafeteria bloqueada no debe borrar cafeteria');
select pg_temp.debe_err(public.editar_cafeteria('admin-prueba', 'cafe-a', 'Nombre Nuevo'), 'bloqueado', 'h: editar_cafeteria con clave correcta tras 30 fallos');
select pg_temp.chk((select nombre from public.cafeterias where slug = 'cafe-a') = 'Cafe A', 'h: una editar_cafeteria bloqueada no debe cambiar el nombre');

-- Todo lo anterior se revierte; el veredicto va al final porque el editor de Supabase solo muestra el último resultado.
rollback;
select 'TODAS LAS PRUEBAS PASARON' as resultado;
