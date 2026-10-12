-- Borra la cafetería «prueba» y TODO lo que se generó con ella (ventas, sellos, canjes y las tarjetas
-- que solo se usaron ahí). No toca datos de las cafeterías reales. Córrelo al terminar tus pruebas.
-- También vacía los intentos fallidos de PIN (fallos_pin), así que quita cualquier bloqueo vigente.

begin;

create temp table _tarjetas_prueba on commit drop as
  select s.tarjeta_id as id
  from sellos s
  group by s.tarjeta_id
  having bool_and(s.cafeteria_id = (select id from cafeterias where slug = 'prueba'));

delete from canjes
  where tarjeta_id in (select id from _tarjetas_prueba)
     or cafeteria_id = (select id from cafeterias where slug = 'prueba');
delete from sellos
  where tarjeta_id in (select id from _tarjetas_prueba)
     or cafeteria_id = (select id from cafeterias where slug = 'prueba');
delete from tokens where cafeteria_id = (select id from cafeterias where slug = 'prueba');
delete from tarjetas where id in (select id from _tarjetas_prueba);
delete from cafeterias where slug = 'prueba';
delete from fallos_pin;

commit;

-- Resultado: cuántas filas quedan (sin la cafetería de prueba).
select (select count(*) from cafeterias) as cafeterias, (select count(*) from tarjetas) as tarjetas,
       (select count(*) from tokens) as tokens, (select count(*) from sellos) as sellos,
       (select count(*) from canjes) as canjes;
