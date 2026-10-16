# Ollin · Lealtad

Fidelización Tlatolli, desarrollada por [OLLIN](https://ollin.digital): tarjeta de sellos con QR generado en caja. Primer programa: Quetzalitos (6 postres y el 7.º gratis).

- Web estática (HTML + CSS + JS planos) pensada para GitHub Pages: `index.html` (solo pide el código del negocio), `caja/` (interfaz del negocio con su logo: QR por venta, canje y acceso al panel), `negocio/` (panel administrativo del propio negocio), `c/` (tarjeta del cliente), `panel/` (solo para ti, por URL directa: métricas de todos y alta, edición y baja de cafeterías con la clave admin) y `mostrador/` (hoja imprimible: letrero e instrucciones para el personal de caja).
- Backend: solo Postgres de Supabase. Toda la lógica está en funciones SQL expuestas por RPC; las tablas no son accesibles desde el cliente. API y reglas en [CONTRATO.md](CONTRATO.md).
- `sql/quetzalito.sql` crea el esquema. `sql/pruebas.sql` (transaccional, con las tablas vacías) y `sql/probar-local.sh` lo prueban; el script necesita Postgres.app en `/Applications/Postgres.app` (usa `psql` y `pgbench`) escuchando en el puerto 54329 (o el de `PGPORT`) y crea una base temporal.
- `sql/limpiar-pruebas.sql` borra la cafetería «prueba» con todo lo generado con ella y además vacía `fallos_pin` (quita cualquier bloqueo vigente).
- `config.js` lleva la URL del proyecto y la llave publishable (pública). Nunca pongas aquí claves secret/service_role ni PIN.
- `vendor/qrcode.js` es qrcode-generator 1.4.4 (MIT), incluido para no depender de un CDN.
- Diseño «selva neón»: `estilo.css` (verdes, rosa mexicano, naranja y azul mexicano sobre fondo oscuro), grecas y personajes de la marca en `img/*.svg` (`quetzal.svg` en los sellos, `quetzalcoatl.svg` en el premio) teñidos o pintados con CSS, tipografías DM Sans e Instrument Serif en `fonts/` (licencia OFL, ver `fonts/OFL.txt`).

Probar localmente: `python3 -m http.server 8000` en esta carpeta y abrir `http://localhost:8000/caja/`.

Agregar un negocio: alta en `panel/` (nombre, escuela/zona, PIN de 6 números). El negocio entra por la portada con su PIN y en «Panel administrativo → Mi tarjeta» pone su logo, color, meta, premio y textos. Para que además venda Quetzalitos, actívale «Distribuidor de Quetzalitos» en `panel/` (Editar cafetería).

Puesta en marcha: pega `sql/quetzalito.sql` (idempotente) y luego `sql/control.sql` en el SQL editor de Supabase. El código de «Control Quetzalitos» está en `sql/control.sql`.
