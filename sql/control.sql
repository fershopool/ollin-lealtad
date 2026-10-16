-- Cuenta «Control Quetzalitos» (super administrador disfrazado de negocio). Pégalo UNA vez en el SQL editor de Supabase,
-- después de quetzalito.sql. Entra por la portada con su PIN y su único botón lleva a /panel/, que sigue pidiendo la clave admin.
-- En el EDITOR de Supabase (no en este archivo) reemplaza TODOS los 000000 por tu PIN de 6 números, distinto al de cualquier negocio.
-- No guardes tu PIN en este archivo ni lo subas al repositorio. Para cambiarlo después, ejecútalo otra vez con el PIN nuevo.
do $$
begin
  if '000000' !~ '^[0-9]{6}$' or '000000' = repeat('0', 6) then
    raise exception 'Reemplaza 000000 por tu PIN de 6 números antes de ejecutar esto';
  end if;
  if exists (select 1 from cafeterias c where c.slug <> 'control-quetzalitos'
             and c.pin_hash = extensions.crypt('000000', c.pin_hash)) then
    raise exception 'Ese PIN ya lo usa otro negocio: elige otro';
  end if;
end $$;

insert into cafeterias (nombre, escuela, slug, pin_hash, tipo, super_admin)
values ('Control Quetzalitos', 'Quetzalitos', 'control-quetzalitos',
        extensions.crypt('000000', extensions.gen_salt('bf', 8)), 'Control', true)
on conflict (slug) do update set pin_hash = excluded.pin_hash, super_admin = true;
