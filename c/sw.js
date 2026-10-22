// Service worker de la tarjeta: muestra los avisos de la cafetería o de Quetzalitos y abre la tarjeta al tocarlos.
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener("push", function (e) {
  var datos = {};
  try { datos = e.data ? e.data.json() : {}; } catch (err) { datos = { titulo: "Tu tarjeta", cuerpo: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(datos.titulo || "Tu tarjeta de sellos", {
    body: datos.cuerpo || "",
    icon: "../img/icono.png",
    badge: "../img/icono.png",
    tag: datos.tag || "aviso",
    data: { url: datos.url || "./" }
  }));
});

self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (lista) {
    for (var i = 0; i < lista.length; i++) {
      if ("focus" in lista[i]) return lista[i].focus();
    }
    return self.clients.openWindow(url);
  }));
});
