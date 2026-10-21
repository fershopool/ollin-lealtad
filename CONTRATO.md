# Contrato Quetzalitos (tarjeta de lealtad)

Módulo de lealtad de OLLIN; Quetzalitos es su primer programa. Backend = solo Postgres de Supabase. El cliente web llama funciones por RPC con la llave pública del proyecto (publishable o anon): `POST {url}/rest/v1/rpc/<funcion>` con cuerpo JSON `{"p_...": ...}`.

## Reglas generales
- Toda función pública (las 18 que llama el cliente) es `security definer`, `set search_path = public, extensions, pg_temp`, y devuelve `json`. Las auxiliares internas empiezan con `_` y el cliente no puede ejecutarlas.
- Los errores de negocio NO se lanzan con `raise`: se devuelven como `{"ok":false,"error":"<codigo>"}`. Motivo: un `raise` revierte la transacción y borraría el registro de intentos fallidos. Éxito: `{"ok":true, ...}`.
- Tablas con RLS activo, sin políticas, y `revoke all` a `anon`/`authenticated`. El cliente solo entra por las funciones.
- Tiempos con `now()`. PIN y clave admin con `extensions.crypt(x, extensions.gen_salt('bf'))`; nunca en claro.
- Meta (sellos para premio) = `config.meta` (por defecto 6; valores menores que 1 se toman como 1). El premio es el postre n.º 7; canjear descuenta `meta` sellos.
- Saldo de una tarjeta = `count(sellos de la tarjeta) - meta * count(canjes con usado_en no nulo de la tarjeta)`.

## Tablas (schema public)
- `cafeterias(id uuid pk, nombre, escuela, slug unique, pin_hash, lat, lng, activa bool default true, tope_hora int default 30, tipo text default 'Cafetería', logo text, color text, meta int default 6, premio text, unidad text, mensaje text, super_admin bool default false, distribuidor bool default false, tema jsonb, creada_en timestamptz, vence_en date)`; `logo` = ruta relativa a la raíz del sitio (p. ej. `img/negocios/burra-blanca.png`) o URL https; `tipo`, `logo`, `color`, `meta`, `premio`, `unidad` y `mensaje` los edita cada negocio con `guardar_config` (página `/negocio/`, «Mi tarjeta»); `distribuidor` solo lo cambia el super admin; `super_admin` marca la cuenta «Control Quetzalitos» (`sql/control.sql`)
- `tarjetas(id uuid pk, creada_en)`
- Programas: `tokens`, `sellos` y `canjes` llevan `programa` (`'q'` = Quetzalitos, compartido; otro valor = id de la cafetería dueña de su programa propio). `canjes.meta` guarda la meta con la que se pidió el premio, así cambiar la meta no altera saldos. Una tarjeta (uuid del teléfono) acumula sellos separados por programa.
- `tokens(id, cafeteria_id, codigo text unique, creado_en, expira_en, usado_en, tarjeta_id, cancelado_en)`; codigo = 12 hex aleatorios (`gen_random_bytes(6)`); vence a los 5 min.
- `sellos(id, tarjeta_id, cafeteria_id, token_id unique, creado_en)`
- `canjes(id, tarjeta_id, cafeteria_id null hasta usarse, codigo text, creado_en, usado_en)`; codigo = 6 dígitos aleatorios; vigente 5 min desde `creado_en`.
- `config(clave pk, valor)`: filas `meta`='6' y `admin_hash` (la crea el usuario; no va en el repo).
- `fallos_pin(creado_en)`: un registro por PIN/código/clave incorrectos.

## Funciones
| Función | Devuelve en éxito | Errores |
|---|---|---|
| `entrar(p_pin text)` | `{ok, cafeteria, escuela, tipo, logo, color, meta, premio, unidad, mensaje, distribuidor, admin, tema, creada_en, vence_en, dias_para_vencer}` (valida el PIN y devuelve la config propia del negocio; `admin` = cuenta de control) | `pin_invalido`, `bloqueado` |
| `crear_venta(p_pin text, p_quetzalitos boolean default false)` | `{ok, codigo, expira_en, cafeteria, programa}` (`p_quetzalitos` = QR del programa Quetzalitos, solo distribuidores) | `pin_invalido`, `bloqueado`, `tope_hora`, `no_distribuidor` |
| `reclamar(p_codigo text, p_tarjeta uuid)` | `{ok, tarjeta_id, sellos, meta, premio_listo, cafeteria, nueva, repetido, programa, config}` | `token_invalido`, `token_usado`, `token_vencido`, `sello_reciente` |
| `tarjeta(p_tarjeta uuid, p_programa text default 'q')` | `{ok, tarjeta_id, sellos, meta, premio_listo, programa, config}` | `tarjeta_invalida` |
| `pedir_canje(p_tarjeta uuid, p_programa text default 'q')` | `{ok, codigo, expira_en}` | `tarjeta_invalida`, `faltan_sellos` |
| `canjear(p_pin text, p_codigo text)` | `{ok, cafeteria, premio, programa}` (premio Quetzalitos: solo distribuidores; premio propio: solo su dueño) | `pin_invalido`, `bloqueado`, `canje_invalido`, `canje_usado`, `canje_vencido`, `faltan_sellos`, `no_distribuidor` |
| `cancelar_venta(p_pin text, p_codigo text)` | `{ok}` (anula un QR aún no escaneado del propio negocio; idempotente; la venta cancelada no cuenta en métricas ni en el tope por hora; reclamarla da `token_cancelado`) | `pin_invalido`, `bloqueado`, `token_invalido`, `token_usado` |
| `guardar_config(p_pin, p_tipo, p_logo, p_color, p_meta, p_premio, p_unidad, p_mensaje)` (todos menos el PIN opcionales; null = no cambiar, `''` borra logo/color/mensaje) | `{ok, tipo, logo, color, meta, premio, unidad, mensaje}` | `pin_invalido`, `bloqueado`, `config_invalida` (tipo 1–30, logo `https://…`, `img/negocios/…` o una foto `data:image/(jpeg|png|webp);base64,…` de hasta 60 000 caracteres (la página del negocio la recorta a 192×192), color `#RRGGBB`, meta 1–50, premio 1–60, unidad 1–20, mensaje ≤120) |
| `guardar_tema(p_pin text, p_tema json)` | `{ok, tema}` (guarda solo lo válido y reemplaza el tema entero; `{}` lo restablece) | `pin_invalido`, `bloqueado`, `tema_invalido` (claves permitidas: `acento`, `acento2`, `fondo` = `#RRGGBB`; `fuente_titulo`, `fuente_texto` ∈ instrument-serif, dm-sans, sistema, georgia, redondeada, mono; `emoji_venta`, `emoji_canje`, `emoji_panel`, `emoji_sello` de 1 a 8 caracteres (`emoji_sello` reemplaza al quetzal en las fichas de la tarjeta del cliente); `fondo_img` = `https://…`, `img/negocios/…` o una foto `data:image/(jpeg|png|webp);base64,…` de hasta 150 000 caracteres) |
| `quetzalitos_config(p_clave text, p_meta int default null, p_premio text default null, p_unidad text default null, p_mensaje text default null)` | `{ok, config}` (la config vigente del programa `'q'`; los parámetros null no se tocan, `''` en el mensaje lo borra; sin parámetros solo lee). Se guarda en `config`: `meta`, `q_premio`, `q_unidad`, `q_mensaje` | `clave_invalida`, `bloqueado`, `config_invalida` (meta 1–50, premio 1–60, unidad 1–20, mensaje ≤120) |
| `set_vencimiento(p_clave text, p_slug text, p_vence date default null, p_meses int default null)` | `{ok, cafeteria, vence_en, dias_para_vencer}` (con `p_vence` fija la fecha; con `p_meses` 1–24 suma meses desde el vencimiento actual o desde hoy si ya venció o no tiene = registrar pago; sin ninguno quita el seguimiento) | `clave_invalida`, `bloqueado`, `no_existe`, `fecha_invalida` |
| `estadisticas(p_pin text, p_desde date default null, p_hasta date default null)` | `{ok, desde, hasta, dias, resumen:{ventas, reclamos, canjes, clientes, nuevos, antiguos, repiten, visitas_por_cliente}, por_hora:[24×{h, ventas, registros, canjes}], por_dia_semana:[7×{d 1=lunes…7=domingo, ventas, reclamos}], serie:[{dia, ventas, reclamos}]}`; fechas locales de México, máximo 366 días, `p_desde` null = desde el inicio del negocio | `pin_invalido`, `bloqueado`, `rango_invalido` |
| `set_distribuidor(p_clave text, p_slug text, p_valor boolean)` | `{ok, cafeteria, distribuidor}` | `clave_invalida`, `bloqueado`, `no_existe` |
| `metricas(p_clave text, p_dias int default null)` | `{ok, filas:[{cafeteria, escuela, slug, activa, tope_hora, distribuidor, creada_en, vence_en, dias_para_vencer, ventas, reclamos, canjes, tarjetas_nuevas}]}` | `clave_invalida`, `bloqueado` |
| `mis_metricas(p_pin text, p_dias int default null)` | `{ok, cafeteria, ventas, reclamos, canjes, tarjetas_nuevas}` (solo del negocio dueño del PIN; mismos conteos que `metricas`) | `pin_invalido`, `bloqueado` |
| `crear_cafeteria(p_clave text, p_nombre text, p_escuela text, p_pin text)` | `{ok, cafeteria, escuela, slug}` (nunca devuelve el PIN) | `clave_invalida`, `bloqueado`, `datos_invalidos`, `pin_formato`, `pin_repetido` |
| `eliminar_cafeteria(p_clave text, p_slug text)` | `{ok, cafeteria, escuela}` | `clave_invalida`, `bloqueado`, `no_existe`, `con_historial` (con `ventas`, `reclamos`, `canjes`) |
| `crear_etiqueta(p_clave text, p_slug text, p_programa text default null, p_uid text default null)` | `{ok, cafeteria, programa, llave}` (`llave` = 16 bytes en hex; se muestra una sola vez; `p_uid` = UID de 7 bytes en hex, 14 caracteres, opcional) | `clave_invalida`, `bloqueado`, `no_existe`, `datos_invalidos`, `nfc_invalido`, `uid_repetido` |
| `llave_de_uid(p_clave text, p_uid text)` | `{ok, llave, cafeteria, slug, programa, activa}` (solo clave admin; para editar una etiqueta ya registrada) | `clave_invalida`, `bloqueado`, `nfc_invalido`, `no_existe` |
| `reclamar_nfc(p_uid text, p_ctr text, p_cmac text, p_tarjeta uuid)` | igual que `reclamar`. Datos de la URL `#uid=<14 hex>&ctr=<6 hex>&cmac=<16 hex>` (SDM en claro: UID y contador mirrored, CMAC con la llave de la etiqueta). El CMAC se calcula sobre el texto `uid` + `ctr` tal como llega. Enfriamiento de 15 min por tarjeta y programa; máximo 4 sellos NFC al día por tarjeta y cafetería; el contador debe ser mayor que el último visto y se consume aun si se rechaza por enfriamiento o tope | `nfc_invalido`, `nfc_usado`, `sello_reciente`, `tope_dia` |
| `editar_cafeteria(p_clave text, p_slug text, p_nombre text default null, p_escuela text default null, p_pin text default null, p_activa boolean default null, p_tope_hora int default null)` | `{ok, cafeteria, escuela, slug, activa, tope_hora, pin_cambiado}` | `clave_invalida`, `bloqueado`, `no_existe`, `datos_invalidos`, `pin_formato`, `pin_repetido`, `tope_invalido` |

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
- **crear_cafeteria**: mismo candado, bloqueo y clave que `metricas` (clave incorrecta → fallo registrado). Normaliza los espacios (cualquier racha de espacios, tabuladores o saltos de línea pasa a un solo espacio y se recorta); `nombre` de 2 a 80 caracteres y `escuela` de 0 a 40 (opcional: puede quedar vacía; el slug sale solo del nombre) (si no, `datos_invalidos`); el PIN debe ser exactamente 6 dígitos (`pin_formato`) y distinto del de cualquier otra cafetería, activa o no (`pin_repetido`: dos PIN iguales se anulan entre sí). El `slug` sale de nombre + escuela sin acentos (áàäâãéèëêíìïîóòöôõúùüûñç) y con guiones (`cafeteria` si no queda ninguna letra) y recibe `-2`, `-3`… si ya existe. El PIN se guarda con hash bcrypt (coste 8). El panel (`/panel/`) la usa con la clave admin que ya tiene en memoria y ofrece generar un PIN aleatorio en el navegador.
- **eliminar_cafeteria**: mismo candado, bloqueo y clave que `metricas`. Busca la cafetería por `slug` (`no_existe` si no hay; no cuenta como fallo). Solo la borra si no tiene tokens (ventas), sellos ni canjes con `cafeteria_id` de ella; con historial devuelve `con_historial` y los tres conteos, porque borrarlo quitaría sellos a las tarjetas de los clientes (y un canje borrado devolvería los sellos ya canjeados). Sin historial el PIN y el slug quedan libres. Desactivar (`activa = false`) sigue siendo por SQL.
- **editar_cafeteria**: mismo candado, bloqueo y clave que `metricas`. Busca por `slug` (`no_existe` sin fallo). Los parámetros `null` no se tocan; el `slug` nunca cambia y el historial (tokens, sellos, canjes) tampoco. Valida TODO antes de escribir (un dato inválido no deja cambios a medias): nombre y escuela con la misma normalización y límites que el alta (`datos_invalidos`); PIN de 6 dígitos (`pin_formato`) distinto del de cualquier OTRA cafetería, activa o no (`pin_repetido`; el propio PIN se acepta y da `pin_cambiado = false`); `tope_hora` entero de 1 a 1000 (`tope_invalido`). `activa = false` impide entrar, vender y canjear con su PIN (`_cafeteria_por_pin` solo ve cafeterías activas) pero conserva el historial y las métricas siguen mostrándola; con `true` vuelve a funcionar. Cambiar el PIN invalida el anterior al instante. Reintentar con el mismo PIN nuevo tras perder la respuesta es seguro (`pin_cambiado = false`).

Limitación documentada: ventas = QR generados desde caja. No se ven ventas donde el personal de caja no tocó el botón.

## Mensualidades
- Cada negocio guarda `creada_en` (alta) y `vence_en` (fecha de vencimiento de la mensualidad; null = sin cobro). Las altas nuevas nacen con vencimiento a 1 mes; los negocios existentes quedan sin vencimiento hasta que el super admin lo fije. Todo se calcula con la fecha de México (`_hoy()`).
- `/panel/` → Métricas → Mensualidades: lista con estado (vencida, por vencer ≤ 3 días, al corriente, sin cobro) y acciones «Registrar pago (+1 mes)», «Elegir fecha» y «Quitar seguimiento» (`set_vencimiento`).
- `/caja/` muestra, al iniciar sesión, un aviso cerrable cuando faltan 3 días o menos (o ya venció); se vuelve a mostrar en cada inicio de sesión. No bloquea el servicio: suspender un negocio sigue siendo manual (`activa = false`).
- `/negocio/` → Resumen usa `estadisticas`: periodo a elegir (hoy, 7 días, 30 días, todo o personalizado) con horas pico, días de la semana, evolución diaria, clientes nuevos y recurrentes y embudo; las gráficas viven en `negocio/graficas.js`.

## Tarjeta del cliente (`/c/`)
- `config` del programa (en `reclamar` y `tarjeta`): `{programa, nombre, tipo, logo, color, meta, premio, unidad, mensaje, sello, tema}`; `sello` = `tema.emoji_sello` del negocio (null en Quetzalitos) y `tema` = el tema visual del negocio, que la página aplica con `Q.tema` (Quetzalitos conserva su diseño neón).
- Toda la tarjeta cabe en una pantalla sin scroll: los sellos se ajustan al alto disponible (máximo 5 por fila con meta > 6). Al completar la tarjeta, `Fiesta.premioListo` lanza confeti; al canjear, `Fiesta.recargar` reinicia la tarjeta con una animación (Quetzalcóatl en Quetzalitos; barrido de luz y emojis en los negocios). Ver `c/fiesta.js`.

## Flujo de pantallas (multi-negocio)
- `/` solo pide el código (el PIN) y llama `entrar`; guarda el PIN en `sessionStorage` y va a `/caja/`.
- `/caja/` es la interfaz del negocio: logo, nombre y tipo (de `entrar`) y tres opciones: generar QR por venta, canjear premio y «Panel administrativo» (`/negocio/`, métricas propias con `mis_metricas`).
- `/negocio/` trae además «Diseño»: el negocio elige colores, tipografías, emojis de sus botones e imagen de fondo con vista previa en vivo; `lib.js` (`Q.tema`) lo aplica como variables CSS en `/negocio/` y `/caja/`.
- `/negocio/` también trae «Mi tarjeta»: el negocio edita tipo, logo, color, meta, palabra para lo que se junta, premio y mensaje, con vista previa.
- La cuenta «Control Quetzalitos» (`sql/control.sql`) entra por la misma portada; su menú solo lleva a `/panel/` (que sigue pidiendo la clave admin). `/panel/` no sale en la portada y desde ahí se activa «Distribuidor de Quetzalitos» por negocio: añade el botón «Generar QR Quetzalitos» (programa compartido) además del QR propio.

## Cliente (compartido por /, /caja, /negocio, /c y /panel)
- `config.js`: `window.QUETZALITO = { url: "https://TU-PROYECTO.supabase.co", key: "TU-LLAVE-PUBLICA" }` (la publishable `sb_publishable_...` o la anon `eyJ...`; nunca la secret/service_role).
- `lib.js` (script plano, sin módulos) define `window.Q`:
  - `Q.rpc(fn, args)` → `Promise<json>` con `fetch` a `/rest/v1/rpc/fn`; cabecera `apikey` siempre y `Authorization: Bearer` solo si la key empieza con `eyJ`. Si la red falla, pasan 12 s sin respuesta o el HTTP no es 2xx, devuelve `{ok:false, error:"red"}`.
  - `Q.msg(codigo)` → texto en español para cada código de error (incluye `red`).
- `estilo.css`: variables de marca y clases `.btn`, `.btn-grande`, `.btn-claro`, `.tarjeta`, `.aviso`, `.error`, `.oculto`, `.centro`.
- Marca («selva neón»): verdes (`#0A2E22`, `#137A5B`, `#1FB67A`), rosa mexicano `#E4007C`, naranja `#FF8A1F` y azul mexicano `#1F5BD6`. Alto contraste, móvil primero, botones de al menos 64 px.
- URL del QR = `new URL("../c/", location.href).href + "#" + codigo` (funciona bajo cualquier ruta; el código va en el hash, que no viaja al servidor).
- La tarjeta del cliente vive en `localStorage["quetzalito.tarjeta"]` (uuid). Sin nombre ni correo.
- El PIN de la cafetería (el que escribe el personal de caja) se guarda en `sessionStorage`; la clave admin solo en memoria.
