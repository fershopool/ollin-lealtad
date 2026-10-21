-- NFC (NTAG 424 DNA, SDM en claro: UID + contador + CMAC) -------------------------
-- La etiqueta escribe en cada toque: #uid=<14 hex>&ctr=<6 hex>&cmac=<16 hex>.
-- El CMAC lo calcula la etiqueta con la llave de su archivo 02 (key 2) sobre el texto "uid" + "ctr" tal cual aparece en la URL.
-- El servidor recalcula el CMAC con la llave de la etiqueta y acepta cada contador una sola vez.

create table if not exists etiquetas (
  id uuid primary key default gen_random_uuid(),
  cafeteria_id uuid not null references cafeterias(id),
  programa text not null,
  llave bytea not null,
  uid bytea,
  ultimo_contador int not null default -1,
  creada_en timestamptz not null default now()
);
alter table etiquetas enable row level security;
revoke all on etiquetas from public, anon, authenticated;
create unique index if not exists etiquetas_uid_idx on etiquetas (uid) where uid is not null;

alter table sellos alter column token_id drop not null;
alter table sellos add column if not exists etiqueta_id uuid references etiquetas(id);
alter table sellos add column if not exists contador int;
create index if not exists sellos_etiqueta_idx on sellos (etiqueta_id, contador);

create or replace function _xor16(a bytea, b bytea) returns bytea
language plpgsql immutable set search_path = public, extensions, pg_temp
as $$
declare r bytea := a; i int;
begin
  for i in 0..15 loop r := set_byte(r, i, get_byte(a, i) # get_byte(b, i)); end loop;
  return r;
end $$;

create or replace function _cmac_dbl(b bytea) returns bytea
language plpgsql immutable set search_path = public, extensions, pg_temp
as $$
declare r bytea := b; i int; carry int := 0; nxt int;
begin
  for i in reverse 15..0 loop
    nxt := (get_byte(b, i) >> 7) & 1;
    r := set_byte(r, i, ((get_byte(b, i) << 1) & 255) | carry);
    carry := nxt;
  end loop;
  if carry = 1 then r := set_byte(r, 15, get_byte(r, 15) # 135); end if;
  return r;
end $$;

-- AES-CMAC (RFC 4493).
create or replace function _cmac(k bytea, m bytea) returns bytea
language plpgsql immutable set search_path = public, extensions, pg_temp
as $$
declare
  cero bytea := decode(repeat('00', 16), 'hex');
  k1 bytea; k2 bytea; x bytea := decode(repeat('00', 16), 'hex'); blk bytea;
  ln int := length(m); n int; i int;
begin
  k1 := _cmac_dbl(extensions.encrypt(cero, k, 'aes-ecb/pad:none'));
  k2 := _cmac_dbl(k1);
  n := greatest((ln + 15) / 16, 1);
  for i in 0..n - 2 loop
    x := extensions.encrypt(_xor16(x, substring(m from i * 16 + 1 for 16)), k, 'aes-ecb/pad:none');
  end loop;
  blk := substring(m from (n - 1) * 16 + 1);
  if ln > 0 and ln % 16 = 0 then
    blk := _xor16(blk, k1);
  else
    blk := _xor16(blk || '\x80'::bytea || decode(repeat('00', 15 - length(blk)), 'hex'), k2);
  end if;
  return extensions.encrypt(_xor16(x, blk), k, 'aes-ecb/pad:none');
end $$;

-- Comprueba el CMAC de una URL SDM en claro, como lo hace el chip (AN12196, pg. 41-42):
-- llave de sesión = CMAC(llave, SV) con SV = 3CC3 0001 0080 || UID (7) || contador LSB (3); el CMAC de la URL es CMAC(sesión, vacío),
-- truncado a los bytes impares (posiciones 2, 4, ... 16).
create or replace function _sdm_plano_verificar(p_uid text, p_ctr text, p_cmac text, p_llave bytea) returns boolean
language plpgsql immutable set search_path = public, extensions, pg_temp
as $$
declare ctr bytea; ses bytea; mac bytea; corto bytea := ''::bytea; i int;
begin
  ctr := decode(p_ctr, 'hex');                              -- en la URL el contador va en MSB
  ses := _cmac(p_llave, '\x3cc300010080'::bytea || decode(p_uid, 'hex')
           || substring(ctr from 3 for 1) || substring(ctr from 2 for 1) || substring(ctr from 1 for 1));
  mac := _cmac(ses, ''::bytea);
  for i in 0..7 loop corto := corto || set_byte('\x00'::bytea, 0, get_byte(mac, i * 2 + 1)); end loop;
  return encode(corto, 'hex') = lower(p_cmac);
end $$;

-- Alta de una etiqueta (clave admin). Devuelve la llave en hex: se graba en la etiqueta y se muestra una sola vez.
-- p_uid (opcional, 14 hex) es el UID de la etiqueta física; si se da, la etiqueta queda ligada a ese UID desde el principio.
create or replace function crear_etiqueta(p_clave text, p_slug text, p_programa text default null, p_uid text default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_hash text; v_cafe cafeterias; v_llave bytea; v_prog text; v_uidb bytea;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;
  select * into v_cafe from cafeterias where slug = p_slug and not super_admin;
  if not found then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  v_prog := coalesce(p_programa, v_cafe.id::text);
  if v_prog <> 'q' and v_prog <> v_cafe.id::text then
    return json_build_object('ok', false, 'error', 'datos_invalidos');
  end if;
  if p_uid is not null then
    if p_uid !~* '^[0-9a-f]{14}$' then
      return json_build_object('ok', false, 'error', 'nfc_invalido');
    end if;
    v_uidb := decode(p_uid, 'hex');
    if exists (select 1 from etiquetas where uid = v_uidb) then
      return json_build_object('ok', false, 'error', 'uid_repetido');
    end if;
  end if;
  v_llave := extensions.gen_random_bytes(16);
  begin
    insert into etiquetas (cafeteria_id, programa, llave, uid) values (v_cafe.id, v_prog, v_llave, v_uidb);
  exception when unique_violation then
    return json_build_object('ok', false, 'error', 'uid_repetido');
  end;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'programa', v_prog, 'llave', encode(v_llave, 'hex'));
end $$;

-- Devuelve la llave de una etiqueta ya ligada a su UID (para editarla: la app se autentica con ella). Solo clave admin.
create or replace function llave_de_uid(p_clave text, p_uid text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare v_hash text; v_et etiquetas; v_cafe cafeterias;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;
  if p_uid is null or p_uid !~* '^[0-9a-f]{14}$' then
    return json_build_object('ok', false, 'error', 'nfc_invalido');
  end if;
  select * into v_et from etiquetas where uid = decode(p_uid, 'hex');
  if not found then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  select * into v_cafe from cafeterias where id = v_et.cafeteria_id;
  return json_build_object('ok', true, 'llave', encode(v_et.llave, 'hex'), 'cafeteria', v_cafe.nombre,
                           'slug', v_cafe.slug, 'programa', v_et.programa, 'activa', v_cafe.activa);
end $$;

-- Sello por NFC. Enfriamiento de 15 min por tarjeta y programa; tope de 4 sellos NFC al día por tarjeta y cafetería.
-- El contador se consume antes de las demás comprobaciones: un enlace rechazado no se puede reutilizar más tarde.
create or replace function reclamar_nfc(p_uid text, p_ctr text, p_cmac text, p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_et etiquetas; v_uidb bytea; v_ctrb bytea; v_ctr int; v_ok boolean := false;
  v_tarj uuid; v_nueva boolean := false; v_repetido boolean := false;
  v_saldo int; v_meta int; v_nombre text; v_n int;
begin
  if p_uid is null or p_ctr is null or p_cmac is null
     or p_uid !~* '^[0-9a-f]{14}$' or p_ctr !~* '^[0-9a-f]{6}$' or p_cmac !~* '^[0-9a-f]{16}$' then
    return json_build_object('ok', false, 'error', 'nfc_invalido');
  end if;
  v_uidb := decode(p_uid, 'hex');
  v_ctrb := decode(p_ctr, 'hex');
  v_ctr := get_byte(v_ctrb, 0) * 65536 + get_byte(v_ctrb, 1) * 256 + get_byte(v_ctrb, 2);  -- MSB en la URL

  -- Etiquetas activas ligadas a este UID, o aún sin UID (las creadas antes de conocer su UID).
  for v_et in select e.* from etiquetas e join cafeterias c on c.id = e.cafeteria_id
      where c.activa and (e.uid = v_uidb or e.uid is null) loop
    if _sdm_plano_verificar(p_uid, p_ctr, p_cmac, v_et.llave) then
      v_ok := true;
      exit;
    end if;
  end loop;
  if not v_ok then
    return json_build_object('ok', false, 'error', 'nfc_invalido');
  end if;

  select * into v_et from etiquetas where id = v_et.id for update;

  if p_tarjeta is not null then
    insert into tarjetas (id) values (p_tarjeta) on conflict (id) do nothing returning id into v_tarj;
    v_nueva := found;
  end if;
  if v_tarj is null then
    if p_tarjeta is null then
      insert into tarjetas default values returning id into v_tarj;
      v_nueva := true;
    else
      select id into v_tarj from tarjetas where id = p_tarjeta for update;
    end if;
  end if;

  if v_ctr = v_et.ultimo_contador and exists (
      select 1 from sellos s where s.etiqueta_id = v_et.id and s.contador = v_ctr and s.tarjeta_id = v_tarj) then
    v_repetido := true;   -- reintento tras perder la respuesta
  elsif v_ctr <= v_et.ultimo_contador then
    return json_build_object('ok', false, 'error', 'nfc_usado');
  else
    update etiquetas set ultimo_contador = v_ctr, uid = v_uidb where id = v_et.id;
    if exists (select 1 from sellos s where s.tarjeta_id = v_tarj and s.cafeteria_id = v_et.cafeteria_id
               and s.programa = v_et.programa and s.creado_en > now() - interval '15 minutes') then
      return json_build_object('ok', false, 'error', 'sello_reciente');
    end if;
    select count(*) into v_n from sellos s where s.tarjeta_id = v_tarj and s.cafeteria_id = v_et.cafeteria_id
      and s.etiqueta_id is not null and (s.creado_en at time zone 'America/Mexico_City')::date = _hoy();
    if v_n >= 4 then
      return json_build_object('ok', false, 'error', 'tope_dia');
    end if;
    insert into sellos (tarjeta_id, cafeteria_id, etiqueta_id, contador, creado_en, programa)
    values (v_tarj, v_et.cafeteria_id, v_et.id, v_ctr, now(), v_et.programa);
  end if;

  v_meta := _meta(v_et.programa);
  v_saldo := _saldo(v_tarj, v_et.programa);
  select nombre into v_nombre from cafeterias where id = v_et.cafeteria_id;
  return json_build_object(
    'ok', true, 'tarjeta_id', v_tarj, 'sellos', v_saldo, 'meta', v_meta,
    'premio_listo', v_saldo >= v_meta, 'cafeteria', v_nombre,
    'nueva', v_nueva, 'repetido', v_repetido,
    'programa', v_et.programa, 'config', _config_programa(v_et.programa));
end $$;

-- Quitar las versiones anteriores (cifradas) si ya existen.
drop function if exists _sdm_verificar(text, text, bytea);
drop function if exists crear_etiqueta(text, text, text);
drop function if exists reclamar_nfc(text, text, uuid);

-- Permisos de lo nuevo
revoke all on function _xor16(bytea, bytea), _cmac_dbl(bytea), _cmac(bytea, bytea), _sdm_plano_verificar(text, text, text, bytea)
  from public, anon, authenticated;
revoke all on function crear_etiqueta(text, text, text, text), llave_de_uid(text, text), reclamar_nfc(text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function crear_etiqueta(text, text, text, text), llave_de_uid(text, text), reclamar_nfc(text, text, text, uuid)
  to anon, authenticated;
