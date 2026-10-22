-- Avisos (notificaciones del celular) sin datos personales: cada suscripción es el identificador del
-- navegador de una tarjeta. Los avisos los crea la cafetería desde su panel, o el super admin para
-- todas las tarjetas de Quetzalitos; la función de envío los manda y los marca como enviados.
-- Idempotente. Se ejecuta después de sql/recomendar.sql.

create table if not exists suscripciones (
  endpoint text primary key,
  tarjeta_id uuid not null references tarjetas(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  creada_en timestamptz not null default now(),
  ultima_vez timestamptz not null default now()
);
create index if not exists suscripciones_tarjeta_idx on suscripciones (tarjeta_id);

create table if not exists avisos (
  id uuid primary key default gen_random_uuid(),
  alcance text not null,                      -- 'q' = todas las tarjetas de Quetzalitos; o id de una cafetería
  titulo text not null check (char_length(titulo) between 1 and 60),
  cuerpo text not null check (char_length(cuerpo) between 1 and 160),
  creado_en timestamptz not null default now(),
  enviado_en timestamptz,
  destinatarios int not null default 0
);
create index if not exists avisos_pendientes_idx on avisos (enviado_en) where enviado_en is null;

alter table suscripciones enable row level security;
alter table avisos enable row level security;
revoke all on suscripciones, avisos from public, anon, authenticated;

-- Tarjetas que reciben un aviso: las que tienen algún sello en la cafetería (o en Quetzalitos).
create or replace function _tarjetas_de_alcance(p_alcance text) returns setof uuid
language sql stable security definer set search_path = public, extensions, pg_temp
as $$
  select distinct s.tarjeta_id from sellos s
  where (p_alcance = 'q' and s.programa = 'q')
     or (p_alcance <> 'q' and s.cafeteria_id::text = p_alcance);
$$;

-- Suscripciones que deben recibir un aviso (lo usa solo la función de envío, con la llave de servicio).
create or replace function audiencia_aviso(p_aviso uuid) returns setof suscripciones
language sql stable security definer set search_path = public, extensions, pg_temp
as $$
  select su.* from suscripciones su
  join avisos a on a.id = p_aviso
  where su.tarjeta_id in (select _tarjetas_de_alcance(a.alcance));
$$;

-- El celular de una tarjeta se suscribe (máximo 5 dispositivos por tarjeta).
create or replace function suscribir_aviso(p_tarjeta uuid, p_endpoint text, p_p256dh text, p_auth text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  if p_tarjeta is null or p_endpoint is null or p_p256dh is null or p_auth is null
     or char_length(p_endpoint) > 600 or char_length(p_p256dh) > 200 or char_length(p_auth) > 100 then
    return json_build_object('ok', false, 'error', 'datos_invalidos');
  end if;
  insert into tarjetas (id) values (p_tarjeta) on conflict (id) do nothing;
  insert into suscripciones (endpoint, tarjeta_id, p256dh, auth) values (p_endpoint, p_tarjeta, p_p256dh, p_auth)
    on conflict (endpoint) do update set tarjeta_id = excluded.tarjeta_id, p256dh = excluded.p256dh,
      auth = excluded.auth, ultima_vez = now();
  delete from suscripciones where tarjeta_id = p_tarjeta and endpoint not in (
    select endpoint from suscripciones where tarjeta_id = p_tarjeta order by ultima_vez desc limit 5);
  return json_build_object('ok', true);
end $$;

create or replace function quitar_aviso(p_endpoint text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  delete from suscripciones where endpoint = p_endpoint;
  return json_build_object('ok', true);
end $$;

-- Aviso de una cafetería a sus clientes (con su PIN). Máximo 3 al día.
create or replace function enviar_aviso_cafe(p_pin text, p_titulo text, p_cuerpo text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_cafe cafeterias; v_id uuid; v_hoy int;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  if char_length(trim(coalesce(p_titulo, ''))) not between 1 and 60
     or char_length(trim(coalesce(p_cuerpo, ''))) not between 1 and 160 then
    return json_build_object('ok', false, 'error', 'aviso_invalido');
  end if;
  select count(*) into v_hoy from avisos where alcance = v_cafe.id::text and creado_en > now() - interval '1 day';
  if v_hoy >= 3 then
    return json_build_object('ok', false, 'error', 'limite_diario');
  end if;
  insert into avisos (alcance, titulo, cuerpo) values (v_cafe.id::text, trim(p_titulo), trim(p_cuerpo)) returning id into v_id;
  return json_build_object('ok', true, 'aviso', v_id);
end $$;

-- Aviso del super admin a todas las tarjetas de Quetzalitos. Máximo 5 al día.
create or replace function enviar_aviso_general(p_clave text, p_titulo text, p_cuerpo text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_hash text; v_hoy int; v_id uuid;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;
  if char_length(trim(coalesce(p_titulo, ''))) not between 1 and 60
     or char_length(trim(coalesce(p_cuerpo, ''))) not between 1 and 160 then
    return json_build_object('ok', false, 'error', 'aviso_invalido');
  end if;
  select count(*) into v_hoy from avisos where alcance = 'q' and creado_en > now() - interval '1 day';
  if v_hoy >= 5 then
    return json_build_object('ok', false, 'error', 'limite_diario');
  end if;
  insert into avisos (alcance, titulo, cuerpo) values ('q', trim(p_titulo), trim(p_cuerpo)) returning id into v_id;
  return json_build_object('ok', true, 'aviso', v_id);
end $$;

-- Permisos
revoke all on function _tarjetas_de_alcance(text), audiencia_aviso(uuid) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function audiencia_aviso(uuid) to service_role;
  end if;
end $$;
revoke all on function suscribir_aviso(uuid, text, text, text), quitar_aviso(text),
  enviar_aviso_cafe(text, text, text), enviar_aviso_general(text, text, text) from public, anon, authenticated;
grant execute on function suscribir_aviso(uuid, text, text, text), quitar_aviso(text),
  enviar_aviso_cafe(text, text, text), enviar_aviso_general(text, text, text) to anon, authenticated;
