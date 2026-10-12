# Contrato Quetzalitos (tarjeta de lealtad)

Módulo de lealtad de OLLIN; Quetzalitos es su primer programa. Backend = solo Postgres de Supabase. El cliente web llama funciones por RPC con la llave pública del proyecto (publishable o anon): `POST {url}/rest/v1/rpc/<funcion>` con cuerpo JSON `{"p_...": ...}`.

## Reglas generales
- Toda función pública (las 7 que llama el cliente) es `security definer`, `set search_path = public, extensions, pg_temp`, y devuelve `json`. Las auxiliares internas empiezan con `_` y el cliente no puede ejecutarlas.
- Los errores de negocio NO se lanzan con `raise`: se devuelven como `{"ok":false,"error":"<codigo>"}`. Motivo: un `raise` revierte la transacción y borraría el registro de intentos fallidos. Éxito: `{"ok":true, ...}`.
- Tablas con RLS activo, sin políticas, y `revoke all` a `anon`/`authenticated`. El cliente solo entra por las funciones.
- Tiempos con `now()`. PIN y clave admin con `extensions.crypt(x, extensions.gen_salt('bf'))`; nunca en claro.
- Meta (sellos para premio) = `config.meta` (por defecto 6; valores menores que 1 se toman como 1). El premio es el postre n.º 7; canjear descuenta `meta` sellos.
- Saldo de una tarjeta = `count(sellos de la tarjeta) - meta * count(canjes con usado_en no nulo de la tarjeta)`.

## Tablas (schema public)
- `cafeterias(id uuid pk, nombre, escuela, slug unique, pin_hash, lat, lng, activa bool default true, tope_hora int default 30)`
- `tarjetas(id uuid pk, creada_en)`
- `tokens(id, cafeteria_id, codigo text unique, creado_en, expira_en, usado_en, tarjeta_id)`; codigo = 12 hex aleatorios (`gen_random_bytes(6)`); vence a los 5 min.
- `sellos(id, tarjeta_id, cafeteria_id, token_id unique, creado_en)`
- `canjes(id, tarjeta_id, cafeteria_id null hasta usarse, codigo text, creado_en, usado_en)`; codigo = 6 dígitos aleatorios; vigente 5 min desde `creado_en`.
- `config(clave pk, valor)`: filas `meta`='6' y `admin_hash` (la crea el usuario; no va en el repo).
- `fallos_pin(creado_en)`: un registro por PIN/código/clave incorrectos.

## Funciones
| Función | Devuelve en éxito | Errores |
|---|---|---|
| `entrar(p_pin text)` | `{ok, cafeteria, escuela}` (solo valida el PIN) | `pin_invalido`, `bloqueado` |
| `crear_venta(p_pin text)` | `{ok, codigo, expira_en, cafeteria}` | `pin_invalido`, `bloqueado`, `tope_hora` |
| `reclamar(p_codigo text, p_tarjeta uuid)` | `{ok, tarjeta_id, sellos, meta, premio_listo, cafeteria, nueva, repetido}` | `token_invalido`, `token_usado`, `token_vencido`, `sello_reciente` |
| `tarjeta(p_tarjeta uuid)` | `{ok, tarjeta_id, sellos, meta, premio_listo}` | `tarjeta_invalida` |
| `pedir_canje(p_tarjeta uuid)` | `{ok, codigo, expira_en}` | `tarjeta_invalida`, `faltan_sellos` |
| `canjear(p_pin text, p_codigo text)` | `{ok, cafeteria}` | `pin_invalido`, `bloqueado`, `canje_invalido`, `canje_usado`, `canje_vencido`, `faltan_sellos` |
| `metricas(p_clave text, p_dias int default null)` | `{ok, filas:[{cafeteria, escuela, slug, ventas, reclamos, canjes, tarjetas_nuevas}]}` | `clave_invalida`, `bloqueado` |

`sellos` en las respuestas = saldo actual (puede ser mayor que `meta`; la UI muestra `min(sellos, meta)`).

### Lógica por función
- **PIN**: se busca la cafetería activa con `pin_hash = crypt(p_pin, pin_hash)`. Los PIN deben ser únicos entre cafeterías: si dos activas comparten PIN, ninguna coincide (`pin_invalido`), para no atribuir ventas a la equivocada. Antes de comparar: si hay 30 o más filas en `fallos_pin` de los últimos 10 min → `bloqueado` (también con PIN correcto). Si falla → insertar en `fallos_pin` (y borrar las de más de un día) y devolver `pin_invalido`. Lo mismo para `clave_invalida` y para códigos de canje desconocidos (`canje_invalido`). Estas funciones toman un candado de transacción (`pg_advisory_xact_lock`) antes de contar, así que el límite de 30 y el tope por hora son exactos aun con ráfagas en paralelo.
- **crear_venta**: si los tokens de esa cafetería creados en la última hora ≥ `tope_hora` → `tope_hora`. Si no, inserta token (vence en 5 min).
- **reclamar** (bloquear el token `for update`):
  1. No existe → `token_invalido`.
  2. Ya usado: si `p_tarjeta` es la misma que lo usó → `{ok:true, repetido:true}` con el estado actual, SIN nuevo sello; si no → `token_usado`.
  3. `expira_en <= now()` → `token_vencido`.
  4. Tarjeta: si `p_tarjeta` es null se crea una con id aleatorio (`nueva:true`); si es un uuid que no existe, se crea con ESE id (`nueva:true`: el cliente lo genera y lo guarda antes de llamar, así un reintento tras perder la respuesta cae en el caso 2 y no duplica el sello); si ya existe se bloquea su fila `for update` (evita carreras entre dos tokens de la misma tarjeta).
  5. Si la tarjeta ya tiene un sello de esa cafetería en los últimos 10 min → `sello_reciente`.
  6. Insertar sello, marcar token (`usado_en`, `tarjeta_id`), devolver estado.
- **pedir_canje**: bloquea la tarjeta; saldo < meta → `faltan_sellos`. Si ya hay un canje sin usar y vigente (5 min) se devuelve ese mismo código; si no, se crea uno (6 dígitos, sin repetir otro vigente).
- **canjear**: valida PIN; toma el canje más reciente con ese código `for update` y decide sobre la fila bloqueada: ninguno → `canje_invalido` (+fallo); `usado_en` no nulo → `canje_usado`; `creado_en + 5 min <= now()` → `canje_vencido`; bloquea la tarjeta y si saldo < meta → `faltan_sellos`; si todo bien marca `usado_en = now()` y `cafeteria_id`.
- **metricas**: valida `crypt(p_clave, config.admin_hash)` (si no hay `admin_hash` → `clave_invalida`). Una fila por cafetería (incluye ceros). `ventas` = tokens creados; `reclamos` = sellos; `canjes` = canjes con `usado_en`; `tarjetas_nuevas` = tarjetas cuyo primer sello fue en esa cafetería. Cada conteo filtra por la fecha de su propio evento si `p_dias` no es null (se limita a 1–36500 días).

Limitación documentada: ventas = QR generados por la cajera. No se ven ventas donde la cajera no tocó el botón.

## Cliente (compartido por /caja, /c y /panel)
- `config.js`: `window.QUETZALITO = { url: "https://TU-PROYECTO.supabase.co", key: "TU-LLAVE-PUBLICA" }` (la publishable `sb_publishable_...` o la anon `eyJ...`; nunca la secret/service_role).
- `lib.js` (script plano, sin módulos) define `window.Q`:
  - `Q.rpc(fn, args)` → `Promise<json>` con `fetch` a `/rest/v1/rpc/fn`; cabecera `apikey` siempre y `Authorization: Bearer` solo si la key empieza con `eyJ`. Si la red falla, pasan 12 s sin respuesta o el HTTP no es 2xx, devuelve `{ok:false, error:"red"}`.
  - `Q.msg(codigo)` → texto en español para cada código de error (incluye `red`).
- `estilo.css`: variables de marca y clases `.btn`, `.btn-grande`, `.btn-claro`, `.tarjeta`, `.aviso`, `.error`, `.oculto`, `.centro`.
- Marca: crema `#F1EBD0`, café `#34241C`, verde `#2E6458`, naranja `#EA9C1E`. Alto contraste, móvil primero, botones de al menos 64 px.
- URL del QR = `new URL("../c/", location.href).href + "#" + codigo` (funciona bajo cualquier ruta; el código va en el hash, que no viaja al servidor).
- La tarjeta del cliente vive en `localStorage["quetzalito.tarjeta"]` (uuid). Sin nombre ni correo.
- El PIN de la cajera se guarda en `sessionStorage`; la clave admin solo en memoria.
