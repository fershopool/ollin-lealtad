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
select pg_temp.debe_err(public.crear_cafeteria('admin-prueba', 'Cafe N', '', '555000'), 'datos_invalidos', 'n: escuela vacia');
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

-- Todo lo anterior se revierte; el veredicto va al final porque el editor de Supabase solo muestra el último resultado.
rollback;
select 'TODAS LAS PRUEBAS PASARON' as resultado;
