# Ollin · Lealtad

Módulo de lealtad de [OLLIN](https://ollin.digital): tarjeta de sellos con QR generado en caja. Primer programa: Quetzalitos (6 postres y el 7.º gratis).

- Web estática (HTML + CSS + JS planos) pensada para GitHub Pages: `caja/` (cajeras), `c/` (tarjeta del cliente), `panel/` (métricas) y `mostrador/` (hoja imprimible: letrero e instrucciones para la cajera).
- Backend: solo Postgres de Supabase. Toda la lógica está en funciones SQL expuestas por RPC; las tablas no son accesibles desde el cliente. API y reglas en [CONTRATO.md](CONTRATO.md).
- `sql/quetzalito.sql` crea el esquema. `sql/pruebas.sql` (transaccional, con las tablas vacías) y `sql/probar-local.sh` lo prueban; el script necesita Postgres.app en `/Applications/Postgres.app` (usa `psql` y `pgbench`) escuchando en el puerto 54329 y crea una base temporal.
- `sql/limpiar-pruebas.sql` borra la cafetería «prueba» con todo lo generado con ella y además vacía `fallos_pin` (quita cualquier bloqueo vigente).
- `config.js` lleva la URL del proyecto y la llave publishable (pública). Nunca pongas aquí claves secret/service_role ni PIN.
- `vendor/qrcode.js` es qrcode-generator 1.4.4 (MIT), incluido para no depender de un CDN.

Probar localmente: `python3 -m http.server 8000` en esta carpeta y abrir `http://localhost:8000/caja/`.
