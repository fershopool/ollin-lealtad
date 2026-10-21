# Etiquetas NFC (NTAG 424 DNA)

Una etiqueta fija por cafetería. Cada toque genera una URL distinta y firmada; el servidor (`reclamar_nfc`, ver CONTRATO.md) acepta cada contador una sola vez, así que copiar o compartir el enlace no sirve.

## 1. Instalar en Supabase
Pega `sql/quetzalito.sql` en el editor SQL (es idempotente). Ya incluye las tablas y funciones NFC.

## 2. Crear la llave de la etiqueta
Desde el panel: al crear una cafetería marca «Crear también su etiqueta NFC», o en Editar cafetería elige el local y pulsa «Crear etiqueta NFC». Te muestra la llave y la URL con botón de copiar. Alternativa en el editor SQL (la clave admin es la del panel):

```sql
select crear_etiqueta('TU-CLAVE-ADMIN', 'slug-de-la-cafeteria');
```

Devuelve `llave` (32 caracteres hex). Se muestra una sola vez: guárdala. Una llave por etiqueta; cada llamada crea una etiqueta nueva.

## 3. Grabar la etiqueta (celular Android + app NXP TagWriter)
Los nombres de menú pueden variar según la versión de la app; lo que importa es esta configuración:

- URL: `https://lealtad.ollin.digital/c/#e=00000000000000000000000000000000&c=0000000000000000`
  (los ceros son marcadores: la etiqueta los reemplaza en cada toque).
- Activar SDM/SUN con: **UID y contador** cifrados en `e` (PICCData, 32 hex) y **CMAC** en `c` (16 hex). El CMAC se calcula sin datos adicionales (sin «MAC input»).
- Llave para SDM (la de lectura de archivo / metadatos): la `llave` del paso 2, AES-128. Usa la misma llave para cifrar el PICCData y para el CMAC.
- No uses el bloqueo permanente de escritura: es irreversible. Con la llave puesta nadie puede reescribirla sin conocerla, y tú podrás editarla después.

## 4. Probar
1. Toca la etiqueta dos veces y mira la URL: `e` y `c` deben cambiar en cada toque.
2. Abre una URL con tu tarjeta: debe sumar un sello.
3. Abre la misma URL otra vez: «Este sello ya estaba agregado» (misma tarjeta) o «Este toque ya se usó» (otra tarjeta).

Si el paso 2 da «Esta etiqueta no es válida», la llave o el formato (mayúsculas/minúsculas no importan; sí el largo 32 y 16) no coinciden con lo grabado.

## Reglas
- Enfriamiento de 15 min por tarjeta y programa; máximo 4 sellos NFC al día por tarjeta y cafetería (constantes en `reclamar_nfc`).
- Un toque que el celular no abre también gasta contador; no pasa nada, el siguiente es mayor.
- Los sellos NFC cuentan como `reclamos` en métricas y no como `ventas`.
