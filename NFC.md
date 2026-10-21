# Etiquetas NFC (NTAG 424 DNA)

Una etiqueta fija por cafetería. Cada toque genera una URL distinta:
`https://lealtad.ollin.digital/c/#uid=<UID>&ctr=<contador>&cmac=<firma>`.
El servidor (`reclamar_nfc`, ver CONTRATO.md) recalcula la firma con la llave de la etiqueta y acepta cada contador una sola vez: copiar o compartir el enlace no sirve.

## 1. Instalar en Supabase
Pega `sql/nfc.sql` en el SQL Editor y pulsa Run. Es idempotente. Crea la tabla `etiquetas` y las funciones `crear_etiqueta`, `llave_de_uid` y `reclamar_nfc`.
Si ya habías ejecutado la versión anterior, este archivo la reemplaza (borra las funciones cifradas).

## 2. Instalar la app
App **Etiquetas Ollin** (Android 7 o superior, con NFC). Se instala como APK (ver el mensaje con el archivo). Base: [AndroidCrypto/Ntag424SdmFeature](https://github.com/AndroidCrypto/Ntag424SdmFeature), MIT.

## 3. Crear una etiqueta nueva (etiqueta de fábrica)
1. Abre la app. Escribe la **clave admin** (no se guarda) y el **código de la cafetería** (el slug, por ejemplo `cafe-del-campus`).
2. Pulsa **Crear etiqueta nueva**.
3. Acerca la etiqueta a la parte trasera del celular y no la muevas.
4. La app muestra "Listo" cuando la etiqueta ya tiene su llave y su URL.

La app pide al servidor una llave nueva para esa etiqueta y la graba. Sin copiar ni pegar.

## 4. Editar una etiqueta ya registrada
1. Escribe la clave admin. El código de la cafetería no hace falta.
2. Pulsa **Editar etiqueta existente** y acerca la etiqueta.
3. La app busca su llave por UID y reescribe la URL.

## 5. Probar
1. Toca la etiqueta con el celular. La URL debe abrir la tarjeta del cliente.
2. Ábrela con una tarjeta: debe sumar un sello en esa cafetería.
3. Tócala otra vez con la misma tarjeta: "ya estaba agregado".
4. Una etiqueta de otra cafetería no suma en la primera.

## Reglas
- Enfriamiento de 15 min por tarjeta y programa; máximo 4 sellos NFC al día por tarjeta y cafetería (constantes en `reclamar_nfc`).
- Un toque que no llega a abrir la página también gasta contador. No pasa nada: el siguiente toque es mayor.
- Los sellos NFC cuentan como `reclamos` en métricas, no como `ventas`.
- Las llaves no se ven en el panel. Si pierdes una, la etiqueta se puede editar solo desde la base de datos (`llave_de_uid` la devuelve con clave admin).
- Antes de pegar una etiqueta en un local, toca dos veces con el celular y confirma que la URL cambia.
