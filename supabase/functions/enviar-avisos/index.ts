// Envía un aviso pendiente (creado por enviar_aviso_cafe o enviar_aviso_general) a los celulares suscritos.
// Se despliega con: supabase functions deploy enviar-avisos --no-verify-jwt
// Secretos: VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT (ej. mailto:tu@correo). SUPABASE_URL y la llave de servicio ya vienen.
import webpush from "npm:web-push@3.6.7";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:soporte@ollin.digital",
  Deno.env.get("VAPID_PUBLIC")!,
  Deno.env.get("VAPID_PRIVATE")!,
);

const cabeceras = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" };
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "metodo" }, 405);
  const { aviso } = await req.json().catch(() => ({ aviso: "" }));
  if (typeof aviso !== "string" || !/^[0-9a-f-]{36}$/i.test(aviso)) return json({ ok: false, error: "aviso_invalido" }, 400);

  // Solo avisos pendientes: un aviso ya enviado no se vuelve a mandar.
  const pendientes = await fetch(`${SB_URL}/rest/v1/avisos?id=eq.${aviso}&enviado_en=is.null&select=*`, { headers: cabeceras })
    .then((r) => r.json());
  if (!pendientes.length) return json({ ok: false, error: "no_pendiente" }, 404);
  const av = pendientes[0];

  const subs = await fetch(`${SB_URL}/rest/v1/rpc/audiencia_aviso`, {
    method: "POST", headers: cabeceras, body: JSON.stringify({ p_aviso: aviso }),
  }).then((r) => r.json());

  const payload = JSON.stringify({ titulo: av.titulo, cuerpo: av.cuerpo, url: "./", tag: `aviso-${aviso}` });
  let enviados = 0;
  for (const s of subs as { endpoint: string; p256dh: string; auth: string }[]) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      enviados++;
    } catch (e) {
      // 404/410: el navegador ya no existe o revocó el permiso; se borra la suscripción.
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await fetch(`${SB_URL}/rest/v1/suscripciones?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: "DELETE", headers: cabeceras });
      }
    }
  }

  await fetch(`${SB_URL}/rest/v1/avisos?id=eq.${aviso}`, {
    method: "PATCH", headers: cabeceras,
    body: JSON.stringify({ enviado_en: new Date().toISOString(), destinatarios: enviados }),
  });
  return json({ ok: true, enviados });
});
