# Ollin · Lealtad

Módulo de lealtad de [OLLIN](https://ollin.digital): tarjeta de sellos con QR generado en caja. Primer programa: Quetzalitos (6 postres y el 7.º gratis).

- Web estática (HTML + CSS + JS planos) pensada para GitHub Pages: `caja/` (cajeras), `c/` (tarjeta del cliente), `panel/` (métricas).
- Backend: solo Postgres de Supabase. Toda la lógica está en funciones SQL expuestas por RPC; las tablas no son accesibles desde el cliente. API y reglas en [CONTRATO.md](CONTRATO.md).
- `sql/quetzalito.sql` crea el esquema; `sql/pruebas.sql` y `sql/probar-local.sh` lo prueban (el script usa un Postgres local); `sql/limpiar-pruebas.sql` borra los datos de la cafetería de prueba.
- `config.js` lleva la URL del proyecto y la llave publishable (pública). Nunca pongas aquí claves secret/service_role ni PIN.

Probar localmente: `python3 -m http.server 8000` en esta carpeta y abrir `http://localhost:8000/caja/`.
