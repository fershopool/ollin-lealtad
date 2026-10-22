-- Recomendaciones sin datos personales: cada tarjeta tiene un código; el amigo que recomendaste
-- y que hace su primera compra real (sello con QR o NFC) te da sellos en esa cafetería.
-- Idempotente. Se ejecuta después de sql/quetzalito.sql y sql/nfc.sql.

-- Reglas por cafetería (editables desde el panel de la cafetería)
alter table cafeterias add column if not exists rec_activo boolean not null default true;
alter table cafeterias add column if not exists rec_amigos int not null default 5;
alter table cafeterias add column if not exists rec_sellos_amigo int not null default 0;
alter table cafeterias add column if not exists rec_sellos_bono int not null default 1;
alter table cafeterias drop constraint if exists cafeterias_rec_chk;
alter table cafeterias add constraint cafeterias_rec_chk check (
  rec_amigos between 1 and 50 and rec_sellos_amigo between 0 and 5 and rec_sellos_bono between 0 and 10);

create table if not exists recomendaciones (
  codigo text primary key,
  referidor uuid not null unique references tarjetas(id),
  creada_en timestamptz not null default now()
);
create table if not exists referidos (
  tarjeta_id uuid primary key references tarjetas(id),
  codigo text not null references recomendaciones(codigo),
  creada_en timestamptz not null default now(),
  acreditado_en timestamptz,
  cafeteria_id uuid references cafeterias(id)   -- null = acreditado sin pago (tope mensual)
);
create index if not exists referidos_codigo_idx on referidos (codigo, cafeteria_id);
alter table recomendaciones enable row level security;
alter table referidos enable row level security;
revoke all on recomendaciones, referidos from public, anon, authenticated;

-- Código de la tarjeta (se crea una vez).
create or replace function codigo_recomendacion(p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_cod text;
begin
  if p_tarjeta is null or not exists (select 1 from tarjetas where id = p_tarjeta) then
    return json_build_object('ok', false, 'error', 'tarjeta_invalida');
  end if;
  select codigo into v_cod from recomendaciones where referidor = p_tarjeta;
  while v_cod is null loop
    begin
      v_cod := encode(extensions.gen_random_bytes(6), 'hex');
      insert into recomendaciones (codigo, referidor) values (v_cod, p_tarjeta);
    exception when unique_violation then
      v_cod := null;
      select codigo into v_cod from recomendaciones where referidor = p_tarjeta;  -- otra llamada ya lo creó
    end;
  end loop;
  return json_build_object('ok', true, 'codigo', v_cod);
end $$;

-- Un amigo se registra con el código: su tarjeta nueva queda ligada al recomendador (sin sellos todavía).
create or replace function registrar_referido(p_codigo text, p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_ref uuid;
begin
  if p_codigo is null or p_codigo !~* '^[0-9a-f]{12}$' or p_tarjeta is null then
    return json_build_object('ok', false, 'error', 'codigo_invalido');
  end if;
  select referidor into v_ref from recomendaciones where codigo = lower(p_codigo);
  if v_ref is null then
    return json_build_object('ok', false, 'error', 'codigo_invalido');
  end if;
  if v_ref = p_tarjeta then
    return json_build_object('ok', false, 'error', 'propia');
  end if;
  insert into tarjetas (id) values (p_tarjeta) on conflict (id) do nothing;
  if exists (select 1 from referidos where tarjeta_id = p_tarjeta) then
    return json_build_object('ok', false, 'error', 'ya_registrado');
  end if;
  if exists (select 1 from sellos where tarjeta_id = p_tarjeta) then
    return json_build_object('ok', false, 'error', 'ya_tiene_sellos');
  end if;
  insert into referidos (tarjeta_id, codigo) values (p_tarjeta, lower(p_codigo));
  return json_build_object('ok', true);
end $$;

-- Al hacer su primera compra real (sello con token o NFC), se acredita al recomendador.
-- Los sellos de recompensa no tienen token ni etiqueta: no disparan esta función.
create or replace function _acreditar_referido() returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_codigo text; v_refi uuid; v_caf cafeterias; v_pagados int; v_en_caf int; i int;
begin
  if new.token_id is null and new.etiqueta_id is null then return new; end if;
  select codigo into v_codigo from referidos where tarjeta_id = new.tarjeta_id and acreditado_en is null for update;
  if v_codigo is null then return new; end if;
  select referidor into v_refi from recomendaciones where codigo = v_codigo;
  select * into v_caf from cafeterias where id = new.cafeteria_id;

  -- Tope: máximo 10 amigos pagados por recomendador y mes.
  select count(*) into v_pagados from referidos r join recomendaciones c on c.codigo = r.codigo
    where c.referidor = v_refi and r.cafeteria_id is not null and r.acreditado_en >= date_trunc('month', now());
  if not v_caf.rec_activo or v_pagados >= 10 then
    update referidos set acreditado_en = now() where tarjeta_id = new.tarjeta_id;   -- sin pago
    return new;
  end if;

  update referidos set acreditado_en = now(), cafeteria_id = new.cafeteria_id where tarjeta_id = new.tarjeta_id;
  for i in 1..v_caf.rec_sellos_amigo loop
    insert into sellos (tarjeta_id, cafeteria_id, creado_en, programa) values (v_refi, new.cafeteria_id, now(), new.programa);
  end loop;

  -- Bono: cada N amigos que compran en esta cafetería.
  select count(*) into v_en_caf from referidos r join recomendaciones c on c.codigo = r.codigo
    where c.referidor = v_refi and r.cafeteria_id = new.cafeteria_id;
  if v_caf.rec_sellos_bono > 0 and v_en_caf % v_caf.rec_amigos = 0 then
    for i in 1..v_caf.rec_sellos_bono loop
      insert into sellos (tarjeta_id, cafeteria_id, creado_en, programa) values (v_refi, new.cafeteria_id, now(), new.programa);
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists sellos_acreditar_referido on sellos;
create trigger sellos_acreditar_referido after insert on sellos
  for each row execute function _acreditar_referido();

-- Panel de la cafetería: leer y guardar sus reglas (con su PIN).
create or replace function leer_recomendacion(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_cafe cafeterias;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  return json_build_object('ok', true, 'activo', v_cafe.rec_activo, 'amigos', v_cafe.rec_amigos,
    'sellos_amigo', v_cafe.rec_sellos_amigo, 'sellos_bono', v_cafe.rec_sellos_bono);
end $$;

create or replace function guardar_recomendacion(p_pin text, p_activo boolean, p_amigos int,
  p_sellos_amigo int, p_sellos_bono int) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_cafe cafeterias;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  if p_amigos not between 1 and 50 or p_sellos_amigo not between 0 and 5 or p_sellos_bono not between 0 and 10 then
    return json_build_object('ok', false, 'error', 'config_invalida');
  end if;
  update cafeterias set rec_activo = coalesce(p_activo, rec_activo), rec_amigos = p_amigos,
    rec_sellos_amigo = p_sellos_amigo, rec_sellos_bono = p_sellos_bono where id = v_cafe.id;
  return json_build_object('ok', true, 'activo', coalesce(p_activo, v_cafe.rec_activo), 'amigos', p_amigos,
    'sellos_amigo', p_sellos_amigo, 'sellos_bono', p_sellos_bono);
end $$;

-- Permisos
revoke all on function codigo_recomendacion(uuid), registrar_referido(text, uuid), _acreditar_referido(),
  leer_recomendacion(text), guardar_recomendacion(text, boolean, int, int, int) from public, anon, authenticated;
grant execute on function codigo_recomendacion(uuid), registrar_referido(text, uuid),
  leer_recomendacion(text), guardar_recomendacion(text, boolean, int, int, int) to anon, authenticated;
