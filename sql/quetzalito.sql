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

-- Personalización por negocio: tipo («Cafetería», «Bar»…) y logo (ruta relativa a la raíz del sitio, p. ej. img/negocios/burra-blanca.png, o URL https).
alter table cafeterias add column if not exists tipo text not null default 'Cafetería';
alter table cafeterias add column if not exists logo text;
-- Programa de lealtad propio del negocio, editable por él (guardar_config): color de acento, meta, premio, palabra para lo que se junta y mensaje.
alter table cafeterias add column if not exists color text;
alter table cafeterias add column if not exists meta int not null default 6;
alter table cafeterias add column if not exists premio text not null default 'Premio de la casa';
alter table cafeterias add column if not exists unidad text not null default 'sellos';
alter table cafeterias add column if not exists mensaje text;
-- «Control Quetzalitos»: cuenta cuyo menú solo lleva al panel de super administrador (que sigue pidiendo la clave admin).
-- Tema visual de las pantallas del negocio (colores, tipografías, emojis, imagen de fondo); lo valida guardar_tema.
alter table cafeterias add column if not exists tema jsonb;
-- Seguimiento de la mensualidad: fecha de alta y fecha en que vence (null = sin cobro). Los negocios que ya existían quedan con la fecha de esta migración
-- como alta y sin vencimiento; los nuevos nacen con vencimiento a 1 mes. Las fechas se calculan en hora de la Ciudad de México.
alter table cafeterias add column if not exists creada_en timestamptz not null default now();
alter table cafeterias add column if not exists vence_en date;
alter table cafeterias add column if not exists super_admin boolean not null default false;
-- Distribuidor de Quetzalitos: las cafeterías que ya existían lo eran, así que nacen en true; las nuevas, en false (el default cambia después).
alter table cafeterias add column if not exists distribuidor boolean not null default true;
alter table cafeterias alter column distribuidor set default false;

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

-- Programa: 'q' = Quetzalitos (compartido); cualquier otro valor = id de la cafetería dueña de su programa propio.
alter table tokens add column if not exists programa text not null default 'q';
-- Venta cancelada por la caja: el QR deja de servir y no cuenta como venta ni en el tope por hora.
alter table tokens add column if not exists cancelado_en timestamptz;
alter table sellos add column if not exists programa text not null default 'q';
alter table canjes add column if not exists programa text not null default 'q';
-- Meta con la que se pidió el premio (null en canjes viejos = meta del programa); así cambiar la meta no altera el saldo ya calculado.
alter table canjes add column if not exists meta int;

create index if not exists sellos_cafeteria_creado_idx on sellos (cafeteria_id, creado_en);
create index if not exists canjes_cafeteria_usado_idx on canjes (cafeteria_id, usado_en);
create index if not exists tokens_cafeteria_creado_idx on tokens (cafeteria_id, creado_en);
create index if not exists sellos_tarjeta_cafeteria_creado_idx on sellos (tarjeta_id, cafeteria_id, creado_en);
create index if not exists canjes_codigo_creado_idx on canjes (codigo, creado_en);
create index if not exists canjes_tarjeta_idx on canjes (tarjeta_id);
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

drop function if exists _meta();
drop function if exists _saldo(uuid);
drop function if exists crear_venta(text);
drop function if exists tarjeta(uuid);
drop function if exists pedir_canje(uuid);

create or replace function _meta(p_programa text default 'q') returns int
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select greatest(coalesce(
    case when p_programa = 'q' then (select valor::int from config where clave = 'meta')
         else (select c.meta from cafeterias c where c.id::text = p_programa) end, 6), 1)
$$;

-- Fecha de hoy en México (Supabase corre en UTC: sin esto «hoy» cambiaría a las 6 pm).
create or replace function _hoy() returns date
language sql stable security definer set search_path = public, extensions, pg_temp
as $$ select (now() at time zone 'America/Mexico_City')::date $$;

-- ponytail: bloqueo global, no por IP (la función no ve la IP del cliente). Un atacante puede bloquear a todo el personal de caja 10 min.
create or replace function _bloqueado() returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
begin
  -- Un intento a la vez: sin este candado, una ráfaga en paralelo se salta el límite porque ninguna ve los fallos sin confirmar de las otras
  -- (y dos ventas simultáneas no pasarían del tope por hora). Se libera al terminar la transacción.
  perform pg_advisory_xact_lock(hashtext('quetzalito.pin'));
  return (select count(*) from fallos_pin f where f.creado_en > now() - interval '10 minutes') >= 30;
end
$$;

create or replace function _registrar_fallo() returns void
language sql security definer set search_path = public, extensions, pg_temp
as $$
  delete from fallos_pin where creado_en < now() - interval '1 day';
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

create or replace function _saldo(p_tarjeta uuid, p_programa text default 'q') returns int
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select ((select count(*) from sellos s where s.tarjeta_id = p_tarjeta and s.programa = p_programa)
          - (select coalesce(sum(coalesce(k.meta, _meta(p_programa))), 0) from canjes k
             where k.tarjeta_id = p_tarjeta and k.programa = p_programa and k.usado_en is not null))::int
$$;

-- Datos para pintar la tarjeta de un programa; null si el programa no existe.
create or replace function _config_programa(p_programa text) returns json
language sql security definer set search_path = public, extensions, pg_temp
as $$
  select case when p_programa = 'q' then
    json_build_object('programa', 'q', 'nombre', 'Quetzalitos', 'tipo', null, 'logo', null, 'color', null,
                      'meta', _meta('q'),
                      'premio', coalesce((select valor from config where clave = 'q_premio'), 'Un postre gratis'),
                      'unidad', coalesce((select valor from config where clave = 'q_unidad'), 'sellos'),
                      'mensaje', (select valor from config where clave = 'q_mensaje'))
  else
    (select json_build_object('programa', c.id::text, 'nombre', c.nombre, 'tipo', c.tipo, 'logo', c.logo, 'color', c.color,
                              'meta', greatest(c.meta, 1), 'premio', c.premio, 'unidad', c.unidad, 'mensaje', c.mensaje,
                              'sello', c.tema->>'emoji_sello', 'tema', c.tema)
     from cafeterias c where c.id::text = p_programa)
  end
$$;

create or replace function _codigo_canje() returns text
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_bytes bytea;
  v_codigo text;
begin
  -- Un solo generador a la vez: sin esto, dos canjes simultáneos de tarjetas distintas podían recibir el mismo código.
  perform pg_advisory_xact_lock(hashtext('quetzalito.canje'));
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
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'escuela', v_cafe.escuela,
                           'tipo', v_cafe.tipo, 'logo', v_cafe.logo, 'color', v_cafe.color,
                           'meta', greatest(v_cafe.meta, 1), 'premio', v_cafe.premio, 'unidad', v_cafe.unidad,
                           'mensaje', v_cafe.mensaje, 'distribuidor', v_cafe.distribuidor, 'admin', v_cafe.super_admin,
                           'tema', v_cafe.tema,
                           'creada_en', v_cafe.creada_en, 'vence_en', v_cafe.vence_en,
                           'dias_para_vencer', case when v_cafe.super_admin or v_cafe.vence_en is null then null
                                                    else v_cafe.vence_en - _hoy() end);
end
$$;

-- p_quetzalitos = true genera el QR del programa Quetzalitos (solo distribuidores); si no, el del programa propio del negocio.
create or replace function crear_venta(p_pin text, p_quetzalitos boolean default false) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_codigo text;
  v_expira timestamptz;
  v_ultima_hora int;
  v_prog text;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  -- La cuenta de control solo entra (entrar) y va al panel de super admin: no vende, canjea ni edita tarjetas.
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  if coalesce(p_quetzalitos, false) and not v_cafe.distribuidor then
    return json_build_object('ok', false, 'error', 'no_distribuidor');
  end if;
  v_prog := case when coalesce(p_quetzalitos, false) then 'q' else v_cafe.id::text end;

  select count(*) into v_ultima_hora from tokens t
  where t.cafeteria_id = v_cafe.id and t.cancelado_en is null and t.creado_en > now() - interval '1 hour';
  if v_ultima_hora >= v_cafe.tope_hora then
    return json_build_object('ok', false, 'error', 'tope_hora');
  end if;

  v_codigo := encode(extensions.gen_random_bytes(6), 'hex');
  insert into tokens (cafeteria_id, codigo, creado_en, expira_en, programa)
  values (v_cafe.id, v_codigo, now(), now() + interval '5 minutes', v_prog)
  returning expira_en into v_expira;

  return json_build_object('ok', true, 'codigo', v_codigo, 'expira_en', v_expira,
                           'cafeteria', v_cafe.nombre, 'programa', v_prog);
end
$$;

-- La caja anula un QR que aún nadie escaneó (error al cobrar, cliente que se arrepiente). Solo el negocio que lo generó.
create or replace function cancelar_venta(p_pin text, p_codigo text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_tok tokens;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  select * into v_tok from tokens where codigo = p_codigo and cafeteria_id = v_cafe.id for update;
  if not found then
    return json_build_object('ok', false, 'error', 'token_invalido');
  end if;
  if v_tok.usado_en is not null then
    return json_build_object('ok', false, 'error', 'token_usado');
  end if;
  if v_tok.cancelado_en is null then
    update tokens set cancelado_en = now() where id = v_tok.id;
  end if;
  return json_build_object('ok', true);
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
  v_meta int;
  v_nombre text;
begin
  select * into v_tok from tokens where codigo = p_codigo for update;
  if not found then
    return json_build_object('ok', false, 'error', 'token_invalido');
  end if;
  v_meta := _meta(v_tok.programa);

  if v_tok.usado_en is not null then
    if p_tarjeta is null or v_tok.tarjeta_id is distinct from p_tarjeta then
      return json_build_object('ok', false, 'error', 'token_usado');
    end if;
    v_repetido := true;
    v_tarj := v_tok.tarjeta_id;
  else
    if v_tok.cancelado_en is not null then
      return json_build_object('ok', false, 'error', 'token_cancelado');
    end if;
    if v_tok.expira_en <= now() then
      return json_build_object('ok', false, 'error', 'token_vencido');
    end if;

    -- El cliente puede traer un uuid nuevo (lo guarda antes de llamar): así reintentar tras perder la respuesta es idempotente.
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

    -- El enfriamiento de 10 min es por programa: se puede sellar el propio y el de Quetzalitos seguidos.
    if exists (
      select 1 from sellos s
      where s.tarjeta_id = v_tarj and s.cafeteria_id = v_tok.cafeteria_id and s.programa = v_tok.programa
        and s.creado_en > now() - interval '10 minutes') then
      return json_build_object('ok', false, 'error', 'sello_reciente');
    end if;

    insert into sellos (tarjeta_id, cafeteria_id, token_id, creado_en, programa)
    values (v_tarj, v_tok.cafeteria_id, v_tok.id, now(), v_tok.programa);
    update tokens set usado_en = now(), tarjeta_id = v_tarj where id = v_tok.id;
  end if;

  v_saldo := _saldo(v_tarj, v_tok.programa);
  select nombre into v_nombre from cafeterias where id = v_tok.cafeteria_id;
  return json_build_object(
    'ok', true, 'tarjeta_id', v_tarj, 'sellos', v_saldo, 'meta', v_meta,
    'premio_listo', v_saldo >= v_meta, 'cafeteria', v_nombre,
    'nueva', v_nueva, 'repetido', v_repetido,
    'programa', v_tok.programa, 'config', _config_programa(v_tok.programa));
end
$$;

create or replace function tarjeta(p_tarjeta uuid, p_programa text default 'q') returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_config json := _config_programa(coalesce(p_programa, 'q'));
  v_meta int := _meta(coalesce(p_programa, 'q'));
  v_saldo int;
begin
  perform 1 from tarjetas where id = p_tarjeta;
  if not found or v_config is null then
    return json_build_object('ok', false, 'error', 'tarjeta_invalida');
  end if;
  v_saldo := _saldo(p_tarjeta, coalesce(p_programa, 'q'));
  return json_build_object('ok', true, 'tarjeta_id', p_tarjeta, 'sellos', v_saldo,
                           'meta', v_meta, 'premio_listo', v_saldo >= v_meta,
                           'programa', coalesce(p_programa, 'q'), 'config', v_config);
end
$$;

create or replace function pedir_canje(p_tarjeta uuid, p_programa text default 'q') returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_prog text := coalesce(p_programa, 'q');
  v_meta int := _meta(coalesce(p_programa, 'q'));
  v_codigo text;
  v_creado timestamptz;
begin
  perform 1 from tarjetas where id = p_tarjeta for update;
  if not found or _config_programa(v_prog) is null then
    return json_build_object('ok', false, 'error', 'tarjeta_invalida');
  end if;
  if _saldo(p_tarjeta, v_prog) < v_meta then
    return json_build_object('ok', false, 'error', 'faltan_sellos');
  end if;

  select k.codigo, k.creado_en into v_codigo, v_creado
  from canjes k
  where k.tarjeta_id = p_tarjeta and k.programa = v_prog and k.usado_en is null
    and k.creado_en > now() - interval '5 minutes'
  order by k.creado_en desc
  limit 1;

  if not found then
    v_codigo := _codigo_canje();
    -- La meta vigente queda en el canje: si el negocio la cambia después, este premio se cobra con la de ahora.
    insert into canjes (tarjeta_id, codigo, creado_en, programa, meta)
    values (p_tarjeta, v_codigo, now(), v_prog, v_meta)
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
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  -- La cuenta de control solo entra (entrar) y va al panel de super admin: no vende, canjea ni edita tarjetas.
  if v_cafe.id is null or v_cafe.super_admin then
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
  -- Premio Quetzalitos: solo distribuidores. Premio propio: solo el negocio dueño de ese programa.
  if v_canje.programa = 'q' then
    if not v_cafe.distribuidor then
      return json_build_object('ok', false, 'error', 'no_distribuidor');
    end if;
  elsif v_canje.programa <> v_cafe.id::text then
    return json_build_object('ok', false, 'error', 'canje_invalido');
  end if;
  if v_canje.usado_en is not null then
    return json_build_object('ok', false, 'error', 'canje_usado');
  end if;
  if v_canje.creado_en + interval '5 minutes' <= now() then
    return json_build_object('ok', false, 'error', 'canje_vencido');
  end if;

  perform 1 from tarjetas where id = v_canje.tarjeta_id for update;
  if _saldo(v_canje.tarjeta_id, v_canje.programa) < coalesce(v_canje.meta, _meta(v_canje.programa)) then
    return json_build_object('ok', false, 'error', 'faltan_sellos');
  end if;

  update canjes set usado_en = now(), cafeteria_id = v_cafe.id where id = v_canje.id;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre,
                           'premio', _config_programa(v_canje.programa)->>'premio', 'programa', v_canje.programa);
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
                  else now() - make_interval(days => least(greatest(p_dias, 1), 36500)) end;

  select coalesce(json_agg(f order by f.escuela, f.cafeteria), '[]'::json) into v_filas
  from (
    select c.nombre as cafeteria, c.escuela, c.slug, c.activa, c.tope_hora, c.distribuidor,
      c.creada_en, c.vence_en,
      case when c.vence_en is null then null else c.vence_en - _hoy() end as dias_para_vencer,
      (select count(*) from tokens t
        where t.cafeteria_id = c.id and t.creado_en >= v_desde and t.cancelado_en is null) as ventas,
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
    where not c.super_admin
  ) f;

  return json_build_object('ok', true, 'filas', v_filas);
end
$$;

-- Panel del propio negocio: con su PIN ve solo sus números (no la clave admin ni a las demás).
create or replace function mis_metricas(p_pin text, p_dias int default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_desde timestamptz;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  -- La cuenta de control solo entra (entrar) y va al panel de super admin: no vende, canjea ni edita tarjetas.
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;
  v_desde := case when p_dias is null then '-infinity'::timestamptz
                  else now() - make_interval(days => least(greatest(p_dias, 1), 36500)) end;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre,
    'ventas', (select count(*) from tokens t where t.cafeteria_id = v_cafe.id and t.creado_en >= v_desde and t.cancelado_en is null),
    'reclamos', (select count(*) from sellos s where s.cafeteria_id = v_cafe.id and s.creado_en >= v_desde),
    'canjes', (select count(*) from canjes k where k.cafeteria_id = v_cafe.id and k.usado_en >= v_desde),
    'tarjetas_nuevas', (select count(*) from (
        select distinct on (s.tarjeta_id) s.cafeteria_id, s.creado_en
        from sellos s order by s.tarjeta_id, s.creado_en) p
      where p.cafeteria_id = v_cafe.id and p.creado_en >= v_desde));
end
$$;

-- Alta de cafetería desde el panel: exige la clave admin. Quien llama elige el PIN (6 dígitos); se guarda con hash y no se devuelve.
create or replace function crear_cafeteria(p_clave text, p_nombre text, p_escuela text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_nombre text := btrim(regexp_replace(coalesce(p_nombre, ''), '\s+', ' ', 'g'));
  v_escuela text := btrim(regexp_replace(coalesce(p_escuela, ''), '\s+', ' ', 'g'));
  v_base text;
  v_slug text;
  v_n int := 1;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;

  if char_length(v_nombre) not between 2 and 80 or char_length(v_escuela) not between 0 and 40 then
    return json_build_object('ok', false, 'error', 'datos_invalidos');
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{6}$' then
    return json_build_object('ok', false, 'error', 'pin_formato');
  end if;
  -- Un PIN compartido anula a las dos cafeterías (_cafeteria_por_pin): se rechaza, también contra las inactivas.
  if exists (select 1 from cafeterias c where c.pin_hash = extensions.crypt(p_pin, c.pin_hash)) then
    return json_build_object('ok', false, 'error', 'pin_repetido');
  end if;

  -- slug: nombre y escuela sin acentos, en minúsculas y con guiones; si ya existe se añade -2, -3...
  -- (el candado de _bloqueado() serializa las altas, así que no hay carrera entre dos llamadas).
  -- (se quitan los acentos antes de pasar a minúsculas: lower() no toca las letras con acento en todas las configuraciones regionales).
  v_base := trim(both '-' from left(regexp_replace(
    lower(translate(btrim(v_nombre || ' ' || v_escuela),
      'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
      'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC')), '[^a-z0-9]+', '-', 'g'), 50));
  if v_base = '' then
    v_base := 'cafeteria';
  end if;
  v_slug := v_base;
  while exists (select 1 from cafeterias where slug = v_slug) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  end loop;

  insert into cafeterias (nombre, escuela, slug, pin_hash, vence_en)
  values (v_nombre, v_escuela, v_slug, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)), (_hoy() + interval '1 month')::date);
  return json_build_object('ok', true, 'cafeteria', v_nombre, 'escuela', v_escuela, 'slug', v_slug);
end
$$;

-- Baja de cafetería desde el panel: exige la clave admin y solo borra una que no tenga ventas, sellos ni canjes.
-- Con historial se niega (con_historial + conteos): borrarlo le quitaría sellos a las tarjetas de los clientes.
create or replace function eliminar_cafeteria(p_clave text, p_slug text) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_cafe cafeterias;
  v_ventas int;
  v_reclamos int;
  v_canjes int;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;

  select * into v_cafe from cafeterias where slug = p_slug for update;
  if v_cafe.id is null then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  select count(*) into v_ventas from tokens where cafeteria_id = v_cafe.id;
  select count(*) into v_reclamos from sellos where cafeteria_id = v_cafe.id;
  select count(*) into v_canjes from canjes where cafeteria_id = v_cafe.id;
  if v_ventas + v_reclamos + v_canjes > 0 then
    return json_build_object('ok', false, 'error', 'con_historial', 'cafeteria', v_cafe.nombre,
                             'ventas', v_ventas, 'reclamos', v_reclamos, 'canjes', v_canjes);
  end if;

  delete from cafeterias where id = v_cafe.id;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'escuela', v_cafe.escuela);
end
$$;

-- Edición de una cafetería desde el panel: exige la clave admin. Los parámetros null no se tocan y el slug nunca cambia.
-- Todo se valida antes de escribir, así que un dato inválido no deja cambios a medias. Con activa = false deja de entrar con su PIN.
create or replace function editar_cafeteria(p_clave text, p_slug text, p_nombre text default null, p_escuela text default null,
                                            p_pin text default null, p_activa boolean default null, p_tope_hora int default null)
returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_cafe cafeterias;
  v_nombre text;
  v_escuela text;
  v_pin_cambiado boolean := false;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;

  select * into v_cafe from cafeterias where slug = p_slug for update;
  if v_cafe.id is null then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;

  v_nombre := v_cafe.nombre;
  if p_nombre is not null then
    v_nombre := btrim(regexp_replace(p_nombre, '\s+', ' ', 'g'));
    if char_length(v_nombre) not between 2 and 80 then
      return json_build_object('ok', false, 'error', 'datos_invalidos');
    end if;
  end if;
  v_escuela := v_cafe.escuela;
  if p_escuela is not null then
    v_escuela := btrim(regexp_replace(p_escuela, '\s+', ' ', 'g'));
    if char_length(v_escuela) not between 0 and 40 then
      return json_build_object('ok', false, 'error', 'datos_invalidos');
    end if;
  end if;
  if p_pin is not null then
    if p_pin !~ '^[0-9]{6}$' then
      return json_build_object('ok', false, 'error', 'pin_formato');
    end if;
    -- Como en el alta: ningún otro PIN (de cafetería activa o no) puede ser igual. El propio PIN se acepta y no cambia nada.
    if exists (select 1 from cafeterias c where c.id <> v_cafe.id and c.pin_hash = extensions.crypt(p_pin, c.pin_hash)) then
      return json_build_object('ok', false, 'error', 'pin_repetido');
    end if;
    v_pin_cambiado := extensions.crypt(p_pin, v_cafe.pin_hash) is distinct from v_cafe.pin_hash;
  end if;
  if p_tope_hora is not null and p_tope_hora not between 1 and 1000 then
    return json_build_object('ok', false, 'error', 'tope_invalido');
  end if;

  update cafeterias set
    nombre = v_nombre,
    escuela = v_escuela,
    pin_hash = case when v_pin_cambiado then extensions.crypt(p_pin, extensions.gen_salt('bf', 8)) else pin_hash end,
    activa = coalesce(p_activa, activa),
    tope_hora = coalesce(p_tope_hora, tope_hora)
  where id = v_cafe.id
  returning * into v_cafe;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'escuela', v_cafe.escuela, 'slug', v_cafe.slug,
                           'activa', v_cafe.activa, 'tope_hora', v_cafe.tope_hora, 'pin_cambiado', v_pin_cambiado);
end
$$;

-- Cada negocio edita su tarjeta con su PIN. Los parámetros null no se tocan; '' borra logo, color o mensaje. Valida TODO antes de escribir.
create or replace function guardar_config(p_pin text, p_tipo text default null, p_logo text default null,
  p_color text default null, p_meta int default null, p_premio text default null,
  p_unidad text default null, p_mensaje text default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_tipo text;
  v_logo text;
  v_color text;
  v_meta int;
  v_premio text;
  v_unidad text;
  v_mensaje text;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  -- La cuenta de control solo entra (entrar) y va al panel de super admin: no vende, canjea ni edita tarjetas.
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;

  v_tipo := case when p_tipo is null then v_cafe.tipo else btrim(regexp_replace(p_tipo, '\s+', ' ', 'g')) end;
  v_logo := case when p_logo is null then v_cafe.logo else nullif(btrim(p_logo), '') end;
  v_color := case when p_color is null then v_cafe.color else nullif(btrim(p_color), '') end;
  v_meta := coalesce(p_meta, v_cafe.meta);
  v_premio := case when p_premio is null then v_cafe.premio else btrim(regexp_replace(p_premio, '\s+', ' ', 'g')) end;
  v_unidad := case when p_unidad is null then v_cafe.unidad else btrim(regexp_replace(p_unidad, '\s+', ' ', 'g')) end;
  v_mensaje := case when p_mensaje is null then v_cafe.mensaje else nullif(btrim(regexp_replace(p_mensaje, '\s+', ' ', 'g')), '') end;

  if char_length(v_tipo) not between 1 and 30
     or (v_logo is not null and not (
           (char_length(v_logo) <= 60000 and v_logo ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$')
        or (char_length(v_logo) <= 300 and v_logo not like '%..%'
            and v_logo ~ '^(https://[^[:space:]"''<>]+|img/negocios/[A-Za-z0-9._/-]+)$')))
     or (v_color is not null and v_color !~ '^#[0-9a-fA-F]{6}$')
     or v_meta not between 1 and 50
     or char_length(v_premio) not between 1 and 60
     or char_length(v_unidad) not between 1 and 20
     or (v_mensaje is not null and char_length(v_mensaje) > 120) then
    return json_build_object('ok', false, 'error', 'config_invalida');
  end if;

  update cafeterias set tipo = v_tipo, logo = v_logo, color = v_color, meta = v_meta,
    premio = v_premio, unidad = v_unidad, mensaje = v_mensaje
  where id = v_cafe.id;

  return json_build_object('ok', true, 'tipo', v_tipo, 'logo', v_logo, 'color', v_color, 'meta', v_meta,
                           'premio', v_premio, 'unidad', v_unidad, 'mensaje', v_mensaje);
end
$$;

-- Tema visual del negocio. p_tema es un objeto con claves opcionales: acento, acento2, fondo (#RRGGBB), fuente_titulo y fuente_texto
-- (de una lista cerrada de fuentes locales), emoji_venta, emoji_canje, emoji_panel, emoji_sello (1 a 8 caracteres; emoji_sello reemplaza al quetzal en las fichas de la tarjeta del cliente) y fondo_img (https, img/negocios/ o una foto data:image de hasta 150 000 caracteres).
-- Guarda solo lo válido y reemplaza el tema entero; vacío o {} lo restablece. Un dato inválido no cambia nada.
create or replace function guardar_tema(p_pin text, p_tema json) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_in jsonb;
  v_out jsonb := '{}'::jsonb;
  k text;
  val text;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  -- La cuenta de control solo entra (entrar) y va al panel de super admin: no vende, canjea ni edita tarjetas.
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;

  v_in := coalesce(p_tema::jsonb, '{}'::jsonb);
  if jsonb_typeof(v_in) is distinct from 'object' then
    return json_build_object('ok', false, 'error', 'tema_invalido');
  end if;
  for k in select jsonb_object_keys(v_in) loop
    if jsonb_typeof(v_in -> k) not in ('string', 'null') then
      return json_build_object('ok', false, 'error', 'tema_invalido');
    end if;
    val := nullif(btrim(v_in ->> k), '');
    continue when val is null;
    if k in ('acento', 'acento2', 'fondo') then
      if val !~ '^#[0-9a-fA-F]{6}$' then return json_build_object('ok', false, 'error', 'tema_invalido'); end if;
    elsif k in ('fuente_titulo', 'fuente_texto') then
      if val not in ('instrument-serif', 'dm-sans', 'sistema', 'georgia', 'redondeada', 'mono') then
        return json_build_object('ok', false, 'error', 'tema_invalido');
      end if;
    elsif k in ('emoji_venta', 'emoji_canje', 'emoji_panel', 'emoji_sello') then
      if char_length(val) > 8 or val ~ '[<>&"''`\\[:space:]]' then return json_build_object('ok', false, 'error', 'tema_invalido'); end if;
    elsif k = 'fondo_img' then
      if not ((char_length(val) <= 150000 and val ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$')
              or (char_length(val) <= 300 and val not like '%..%'
                  and val ~ '^(https://[^[:space:]"''<>()\\]+|img/negocios/[A-Za-z0-9._/-]+)$')) then
        return json_build_object('ok', false, 'error', 'tema_invalido');
      end if;
    else
      return json_build_object('ok', false, 'error', 'tema_invalido');
    end if;
    v_out := v_out || jsonb_build_object(k, val);
  end loop;

  update cafeterias set tema = nullif(v_out, '{}'::jsonb) where id = v_cafe.id;
  return json_build_object('ok', true, 'tema', nullif(v_out, '{}'::jsonb));
end
$$;

-- Super admin: ve y edita la tarjeta del programa Quetzalitos (el diseño no cambia, solo meta, premio, palabra y mensaje).
-- Los parámetros null no se tocan ('' en el mensaje lo borra); con todos null solo devuelve lo vigente.
create or replace function quetzalitos_config(p_clave text, p_meta int default null, p_premio text default null,
  p_unidad text default null, p_mensaje text default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_premio text;
  v_unidad text;
  v_mensaje text;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;

  v_premio := case when p_premio is null then null else btrim(regexp_replace(p_premio, '\s+', ' ', 'g')) end;
  v_unidad := case when p_unidad is null then null else btrim(regexp_replace(p_unidad, '\s+', ' ', 'g')) end;
  v_mensaje := case when p_mensaje is null then null else btrim(regexp_replace(p_mensaje, '\s+', ' ', 'g')) end;
  if (p_meta is not null and p_meta not between 1 and 50)
     or (v_premio is not null and char_length(v_premio) not between 1 and 60)
     or (v_unidad is not null and char_length(v_unidad) not between 1 and 20)
     or (v_mensaje is not null and char_length(v_mensaje) > 120) then
    return json_build_object('ok', false, 'error', 'config_invalida');
  end if;

  if p_meta is not null then
    insert into config (clave, valor) values ('meta', p_meta::text) on conflict (clave) do update set valor = excluded.valor;
  end if;
  if v_premio is not null then
    insert into config (clave, valor) values ('q_premio', v_premio) on conflict (clave) do update set valor = excluded.valor;
  end if;
  if v_unidad is not null then
    insert into config (clave, valor) values ('q_unidad', v_unidad) on conflict (clave) do update set valor = excluded.valor;
  end if;
  if v_mensaje = '' then
    delete from config where clave = 'q_mensaje';
  elsif v_mensaje is not null then
    insert into config (clave, valor) values ('q_mensaje', v_mensaje) on conflict (clave) do update set valor = excluded.valor;
  end if;

  return json_build_object('ok', true, 'config', _config_programa('q'));
end
$$;

-- Super admin: fija el vencimiento de la mensualidad de un negocio. Con p_vence fija esa fecha; con p_meses suma meses desde el vencimiento actual
-- (o desde hoy si ya venció o no tiene: es «registrar pago»); sin ninguno de los dos quita el seguimiento. Mismo candado, bloqueo y clave que metricas.
create or replace function set_vencimiento(p_clave text, p_slug text, p_vence date default null, p_meses int default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_cafe cafeterias;
  v_hoy date := _hoy();
  v_nuevo date;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;
  select * into v_cafe from cafeterias where slug = p_slug and not super_admin for update;
  if not found then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  if p_vence is not null then
    if p_vence < v_hoy - 365 or p_vence > v_hoy + 1830 then
      return json_build_object('ok', false, 'error', 'fecha_invalida');
    end if;
    v_nuevo := p_vence;
  elsif p_meses is not null then
    if p_meses not between 1 and 24 then
      return json_build_object('ok', false, 'error', 'fecha_invalida');
    end if;
    v_nuevo := (greatest(coalesce(v_cafe.vence_en, v_hoy), v_hoy) + make_interval(months => p_meses))::date;
  end if;
  update cafeterias set vence_en = v_nuevo where id = v_cafe.id;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'vence_en', v_nuevo,
                           'dias_para_vencer', case when v_nuevo is null then null else v_nuevo - v_hoy end);
end
$$;

-- Estadísticas del propio negocio en un periodo a elección (fechas locales de México; máximo 366 días; p_desde null = desde el inicio).
-- ventas = QR generados no cancelados; reclamos = QR escaneados; clientes = tarjetas con sello en el periodo; nuevos = primera vez en este local dentro del periodo;
-- repiten = clientes con 2 o más sellos en el periodo. Las horas son hora de México. Un día de la semana va de 1 (lunes) a 7 (domingo).
create or replace function estadisticas(p_pin text, p_desde date default null, p_hasta date default null) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_cafe cafeterias;
  v_tz constant text := 'America/Mexico_City';
  v_hasta date;
  v_desde date;
  v_ini timestamptz;
  v_fin timestamptz;
  v_primero timestamptz;
  v_res json;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  v_cafe := _cafeteria_por_pin(p_pin);
  if v_cafe.id is null or v_cafe.super_admin then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'pin_invalido');
  end if;

  v_hasta := least(coalesce(p_hasta, _hoy()), _hoy());
  if p_desde is null then
    select least(v_cafe.creada_en,
                 (select min(tk.creado_en) from tokens tk where tk.cafeteria_id = v_cafe.id),
                 (select min(se.creado_en) from sellos se where se.cafeteria_id = v_cafe.id))
      into v_primero;
    v_desde := greatest((v_primero at time zone v_tz)::date, v_hasta - 365);
  else
    v_desde := p_desde;
  end if;
  if v_desde > v_hasta or v_hasta - v_desde > 365 then
    return json_build_object('ok', false, 'error', 'rango_invalido');
  end if;
  v_ini := v_desde::timestamp at time zone v_tz;
  v_fin := (v_hasta + 1)::timestamp at time zone v_tz;

  with
    prim as (select se.tarjeta_id, min(se.creado_en) as m from sellos se where se.cafeteria_id = v_cafe.id group by se.tarjeta_id),
    s as (select se.tarjeta_id, se.creado_en from sellos se
          where se.cafeteria_id = v_cafe.id and se.creado_en >= v_ini and se.creado_en < v_fin),
    cli as (select tarjeta_id, count(*) as n from s group by tarjeta_id),
    t as (select tk.creado_en from tokens tk
          where tk.cafeteria_id = v_cafe.id and tk.cancelado_en is null and tk.creado_en >= v_ini and tk.creado_en < v_fin),
    k as (select kj.usado_en from canjes kj
          where kj.cafeteria_id = v_cafe.id and kj.usado_en >= v_ini and kj.usado_en < v_fin),
    nue as (select m from prim where m >= v_ini and m < v_fin)
  select json_build_object(
    'ok', true, 'desde', v_desde, 'hasta', v_hasta, 'dias', v_hasta - v_desde + 1,
    'resumen', json_build_object(
      'ventas', (select count(*) from t),
      'reclamos', (select count(*) from s),
      'canjes', (select count(*) from k),
      'clientes', (select count(*) from cli),
      'nuevos', (select count(*) from nue),
      'antiguos', (select count(*) from cli) - (select count(*) from nue),
      'repiten', (select count(*) from cli where n >= 2),
      'visitas_por_cliente', (select round(coalesce(sum(n)::numeric / nullif(count(*), 0), 0), 1) from cli)),
    'por_hora', (select json_agg(json_build_object(
        'h', g.h,
        'ventas', (select count(*) from t where extract(hour from t.creado_en at time zone v_tz)::int = g.h),
        'registros', (select count(*) from nue where extract(hour from nue.m at time zone v_tz)::int = g.h),
        'canjes', (select count(*) from k where extract(hour from k.usado_en at time zone v_tz)::int = g.h)) order by g.h)
      from generate_series(0, 23) as g(h)),
    'por_dia_semana', (select json_agg(json_build_object(
        'd', g.d,
        'ventas', (select count(*) from t where extract(isodow from t.creado_en at time zone v_tz)::int = g.d),
        'reclamos', (select count(*) from s where extract(isodow from s.creado_en at time zone v_tz)::int = g.d)) order by g.d)
      from generate_series(1, 7) as g(d)),
    'serie', (select json_agg(json_build_object(
        'dia', g.d::date,
        'ventas', (select count(*) from t where (t.creado_en at time zone v_tz)::date = g.d::date),
        'reclamos', (select count(*) from s where (s.creado_en at time zone v_tz)::date = g.d::date)) order by g.d)
      from generate_series(v_desde, v_hasta, interval '1 day') as g(d))
  ) into v_res;
  return v_res;
end
$$;

-- Super admin: activa o desactiva que un negocio sea distribuidor de Quetzalitos (mismo candado, bloqueo y clave que metricas).
create or replace function set_distribuidor(p_clave text, p_slug text, p_valor boolean) returns json
language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
  v_cafe cafeterias;
begin
  if _bloqueado() then
    return json_build_object('ok', false, 'error', 'bloqueado');
  end if;
  select valor into v_hash from config where clave = 'admin_hash';
  if v_hash is null or extensions.crypt(p_clave, v_hash) is distinct from v_hash then
    perform _registrar_fallo();
    return json_build_object('ok', false, 'error', 'clave_invalida');
  end if;
  update cafeterias set distribuidor = coalesce(p_valor, false)
  where slug = p_slug and not super_admin returning * into v_cafe;
  if v_cafe.id is null then
    return json_build_object('ok', false, 'error', 'no_existe');
  end if;
  return json_build_object('ok', true, 'cafeteria', v_cafe.nombre, 'distribuidor', v_cafe.distribuidor);
end
$$;

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

-- Permisos --------------------------------------------------------------------

revoke all on function _meta(text), _bloqueado(), _registrar_fallo(), _cafeteria_por_pin(text),
  _saldo(uuid, text), _config_programa(text), _codigo_canje(), _hoy()
  from public, anon, authenticated;

revoke all on function entrar(text), crear_venta(text, boolean), reclamar(text, uuid), tarjeta(uuid, text),
  pedir_canje(uuid, text), canjear(text, text), metricas(text, int), mis_metricas(text, int), crear_cafeteria(text, text, text, text),
  eliminar_cafeteria(text, text), editar_cafeteria(text, text, text, text, text, boolean, int),
  guardar_config(text, text, text, text, int, text, text, text), set_distribuidor(text, text, boolean),
  guardar_tema(text, json),
  cancelar_venta(text, text),
  quetzalitos_config(text, int, text, text, text),
  set_vencimiento(text, text, date, int), estadisticas(text, date, date)
  from public, anon, authenticated;

grant execute on function entrar(text), crear_venta(text, boolean), reclamar(text, uuid), tarjeta(uuid, text),
  pedir_canje(uuid, text), canjear(text, text), metricas(text, int), mis_metricas(text, int), crear_cafeteria(text, text, text, text),
  eliminar_cafeteria(text, text), editar_cafeteria(text, text, text, text, text, boolean, int),
  guardar_config(text, text, text, text, int, text, text, text), set_distribuidor(text, text, boolean),
  guardar_tema(text, json),
  cancelar_venta(text, text),
  quetzalitos_config(text, int, text, text, text),
  set_vencimiento(text, text, date, int), estadisticas(text, date, date)
  to anon, authenticated;
