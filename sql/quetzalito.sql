-- Quetzalito: tarjeta de lealtad (backend Postgres de Supabase).
-- Idempotente: se puede pegar en el SQL editor las veces que haga falta.
-- No inserta cafeterías, PIN ni admin_hash: eso lo hace el usuario.

create extension if not exists pgcrypto with schema extensions;

-- Tablas ----------------------------------------------------------------------

create table if not exists cafeterias (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  escuela text not null,
  slug text not null unique,
  pin_hash text not null,
  lat double precision,
  lng double precision,
  activa boolean not null default true,
  tope_hora int not null default 30
);

create table if not exists tarjetas (
  id uuid primary key default gen_random_uuid(),
  creada_en timestamptz not null default now()
);

create table if not exists tokens (
  id uuid primary key default gen_random_uuid(),
  cafeteria_id uuid not null references cafeterias(id),
  codigo text not null unique,
  creado_en timestamptz not null default now(),
  expira_en timestamptz not null,
  usado_en timestamptz,
  tarjeta_id uuid references tarjetas(id)
);

create table if not exists sellos (
  id uuid primary key default gen_random_uuid(),
  tarjeta_id uuid not null references tarjetas(id),
  cafeteria_id uuid not null references cafeterias(id),
  token_id uuid not null unique references tokens(id),
  creado_en timestamptz not null default now()
);

create table if not exists canjes (
  id uuid primary key default gen_random_uuid(),
  tarjeta_id uuid not null references tarjetas(id),
  cafeteria_id uuid references cafeterias(id),
  codigo text not null,
  creado_en timestamptz not null default now(),
  usado_en timestamptz
);

create table if not exists config (
  clave text primary key,
  valor text not null
);

create table if not exists fallos_pin (
  id uuid primary key default gen_random_uuid(),
  creado_en timestamptz not null default now()
);

create index if not exists tokens_cafeteria_creado_idx on tokens (cafeteria_id, creado_en);
create index if not exists sellos_tarjeta_cafeteria_creado_idx on sellos (tarjeta_id, cafeteria_id, creado_en);
create index if not exists canjes_codigo_creado_idx on canjes (codigo, creado_en);
create index if not exists fallos_pin_creado_idx on fallos_pin (creado_en);

-- Sin políticas: RLS activo y sin acceso directo. El cliente solo entra por funciones.
alter table cafeterias enable row level security;
alter table tarjetas enable row level security;
alter table tokens enable row level security;
alter table sellos enable row level security;
alter table canjes enable row level security;
alter table config enable row level security;
alter table fallos_pin enable row level security;

revoke all on cafeterias, tarjetas, tokens, sellos, canjes, config, fallos_pin
  from public, anon, authenticated;

insert into config (clave, valor) values ('meta', '6') on conflict do nothing;

-- Auxiliares internas (sin grant a anon/authenticated) ------------------------

create or replace function _meta() returns int
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select coalesce((select valor::int from config where clave = 'meta'), 6)
$$;

-- ponytail: bloqueo global, no por IP (la función no ve la IP del cliente). Un atacante puede bloquear a todas las cajeras 10 min.
create or replace function _bloqueado() returns boolean
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select (select count(*) from fallos_pin f where f.creado_en > now() - interval '10 minutes') >= 30
$$;

create or replace function _registrar_fallo() returns void
language sql security definer set search_path = public, extensions, pg_temp
as $$
  insert into fallos_pin default values
$$;

-- Si dos cafeterías activas comparten PIN, ninguna coincide: así una venta nunca se atribuye a la equivocada.
create or replace function _cafeteria_por_pin(p_pin text) returns cafeterias
language sql security definer set search_path = public, extensions, pg_temp
as $$
  with m as (
    select c.* from cafeterias c
    where c.activa and c.pin_hash = extensions.crypt(p_pin, c.pin_hash)
  )
  select m.* from m where (select count(*) from m) = 1
$$;

create or replace function _saldo(p_tarjeta uuid) returns int
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select ((select count(*) from sellos s where s.tarjeta_id = p_tarjeta)
          - _meta() * (select count(*) from canjes k
                       where k.tarjeta_id = p_tarjeta and k.usado_en is not null))::int
$$;

create or replace function _codigo_canje() returns text
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_bytes bytea;
  v_codigo text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(4);
    v_codigo := lpad((((get_byte(v_bytes, 0)::bigint * 16777216)
                     + get_byte(v_bytes, 1) * 65536
                     + get_byte(v_bytes, 2) * 256
                     + get_byte(v_bytes, 3)) % 1000000)::text, 6, '0');
    exit when not exists (
      select 1 from canjes k
      where k.codigo = v_codigo and k.usado_en is null
        and k.creado_en > now() - interval '5 minutes');
  end loop;
  return v_codigo;
end
$$;

-- Públicas --------------------------------------------------------------------

create or replace function entrar(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'escuela', v_cafe.escuela);
end
$$;

create or replace function crear_venta(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_codigo text;
  v_expira timestamptz;
  v_ultima_hora int;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;

  select count(*) into v_ultima_hora from tokens t
  where t.cafeteria_id = v_cafe.id and t.creado_en > now() - interval '1 hour';
  if v_ultima_hora >= v_cafe.tope_hora then
    return json_build_object('ok', false, 'error', 'tope_hora');
  end if;

  v_codigo := encode(extensions.gen_random_bytes(6), 'hex');
  insert into tokens (cafeteria_id, codigo, creado_en, expira_en)
  values (v_cafe.id, v_codigo, now(), now() + interval '5 minutes')
  returning expira_en into v_expira;

  return json_build_object('ok', true, 'codigo', v_codigo, 'expira_en', v_expira, 'cafeteria', v_cafe.nombre);
end
$$;

create or replace function reclamar(p_codigo text, p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_tok tokens;
  v_tarj uuid;
  v_nueva boolean := false;
  v_repetido boolean := false;
  v_saldo int;
  v_meta int := _meta();
  v_nombre text;
begin
  select * into v_tok from tokens where codigo = p_codigo for update;
  if not found then
    return json_build_object('ok', false, 'error', 'token_invalido');
  end if;

  if v_tok.usado_en is not null then
    if p_tarjeta is null or v_tok.tarjeta_id is distinct from p_tarjeta then
      return json_build_object('ok', false, 'error', 'token_usado');
    end if;
    v_repetido := true;
    v_tarj := v_tok.tarjeta_id;
  else
    if v_tok.expira_en <= now() then
      return json_build_object('ok', false, 'error', 'token_vencido');
    end if;

    select id into v_tarj from tarjetas where id = p_tarjeta for update;
    if not found then
      insert into tarjetas default values returning id into v_tarj;
      v_nueva := true;
    end if;

    if exists (
      select 1 from sellos s
      where s.tarjeta_id = v_tarj and s.cafeteria_id = v_tok.cafeteria_id
        and s.creado_en > now() - interval '10 minutes') then
      return json_build_object('ok', false, 'error', 'sello_reciente');
    end if;

    insert into sellos (tarjeta_id, cafeteria_id, token_id, creado_en)
    values (v_tarj, v_tok.cafeteria_id, v_tok.id, now());
    update tokens set usado_en = now(), tarjeta_id = v_tarj where id = v_tok.id;
  end if;

  v_saldo := _saldo(v_tarj);
  select nombre into v_nombre from cafeterias where id = v_tok.cafeteria_id;
  return json_build_object(
    'ok', true, 'tarjeta_id', v_tarj, 'sellos', v_saldo, 'meta', v_meta,
    'premio_listo', v_saldo >= v_meta, 'cafeteria', v_nombre,
    'nueva', v_nueva, 'repetido', v_repetido);
end
$$;

create or replace function tarjeta(p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_meta int := _meta();
  v_saldo int;
begin
  perform 1 from tarjetas where id = p_tarjeta;
  if not found then
    return json_build_object('ok', false, 'error', 'tarjeta_invalida');
  end if;
  v_saldo := _saldo(p_tarjeta);
  return json_build_object('ok', true, 'tarjeta_id', p_tarjeta, 'sellos', v_saldo,
                           'meta', v_meta, 'premio_listo', v_saldo >= v_meta);
end
$$;

create or replace function pedir_canje(p_tarjeta uuid) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_meta int := _meta();
  v_codigo text;
  v_creado timestamptz;
begin
  perform 1 from tarjetas where id = p_tarjeta for update;
  if not found then
    return json_build_object('ok', false, 'error', 'tarjeta_invalida');
  end if;
  if _saldo(p_tarjeta) < v_meta then
    return json_build_object('ok', false, 'error', 'faltan_sellos');
  end if;

  select k.codigo, k.creado_en into v_codigo, v_creado
  from canjes k
  where k.tarjeta_id = p_tarjeta and k.usado_en is null
    and k.creado_en > now() - interval '5 minutes'
  order by k.creado_en desc
  limit 1;

  if not found then
    v_codigo := _codigo_canje();
    insert into canjes (tarjeta_id, codigo, creado_en)
    values (p_tarjeta, v_codigo, now())
    returning creado_en into v_creado;
  end if;

  return json_build_object('ok', true, 'codigo', v_codigo,
                           'expira_en', v_creado + interval '5 minutes');
end
$$;

create or replace function canjear(p_pin text, p_codigo text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_canje canjes;
  v_meta int := _meta();
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;

  select * into v_canje from canjes k
  where k.codigo = p_codigo
  order by k.creado_en desc
  limit 1
  for update;
  if not found then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'canje_invalido');
  end if;
  if v_canje.usado_en is not null then
    return json_build_object('ok', false, 'error', 'canje_usado');
  end if;
  if v_canje.creado_en + interval '5 minutes' <= now() then
    return json_build_object('ok', false, 'error', 'canje_vencido');
  end if;

  perform 1 from tarjetas where id = v_canje.tarjeta_id for update;
  if _saldo(v_canje.tarjeta_id) < v_meta then
    return json_build_object('ok', false, 'error', 'faltan_sellos');
  end if;

  update canjes set usado_en = now(), cafeteria_id = v_cafe.id where id = v_canje.id;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre);
end
$$;

create or replace function metricas(p_clave text, p_dias int default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_desde timestamptz;
  v_filas json;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;

  v_desde := case when p_dias is null then '-infinity'::timestamptz
                  else now() - make_interval(days => p_dias) end;

  select coalesce(json_agg(f order by f.escuela, f.cafeteria), '[]'::json) into v_filas
  from (
    select c.nombre as cafeteria, c.escuela, c.slug,
      (select count(*) from tokens t
        where t.cafeteria_id = c.id and t.creado_en >= v_desde) as ventas,
      (select count(*) from sellos s
        where s.cafeteria_id = c.id and s.creado_en >= v_desde) as reclamos,
      (select count(*) from canjes k
        where k.cafeteria_id = c.id and k.usado_en >= v_desde) as canjes,
      (select count(*) from (
          select distinct on (s.tarjeta_id) s.cafeteria_id, s.creado_en
          from sellos s
          order by s.tarjeta_id, s.creado_en) p
        where p.cafeteria_id = c.id and p.creado_en >= v_desde) as tarjetas_nuevas
    from cafeterias c
  ) f;

  return json_build_object('ok', true, 'filas', v_filas);
end
$$;

-- Permisos --------------------------------------------------------------------

revoke all on function _meta(), _bloqueado(), _registrar_fallo(), _cafeteria_por_pin(text),
  _saldo(uuid), _codigo_canje()
  from public, anon, authenticated;

revoke all on function entrar(text), crear_venta(text), reclamar(text, uuid), tarjeta(uuid),
  pedir_canje(uuid), canjear(text, text), metricas(text, int)
  from public, anon, authenticated;

grant execute on function entrar(text), crear_venta(text), reclamar(text, uuid), tarjeta(uuid),
  pedir_canje(uuid), canjear(text, text), metricas(text, int)
  to anon, authenticated;
