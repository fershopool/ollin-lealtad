// Pantalla de entrada: pide el código del negocio y pasa a caja/. El PIN solo vive en sessionStorage.
(function () {
  "use strict";

  var CLAVE_PIN = "quetzalito.pin";
  var CLAVE_TARJETA = "quetzalito.tarjeta";
  var $ = function (id) { return document.getElementById(id); };

  function leerPin() {
    try { return sessionStorage.getItem(CLAVE_PIN) || ""; } catch (e) { return ""; }
  }
  function guardarPin(pin) {
    try { sessionStorage.setItem(CLAVE_PIN, pin); } catch (e) { /* sin sessionStorage caja vuelve aquí */ }
  }
  function hayTarjeta() {
    try { return !!localStorage.getItem(CLAVE_TARJETA); } catch (e) { return false; }
  }

  // tipo: "aviso", "error" o "" (vacío oculta el mensaje)
  function mensaje(el, texto, tipo) {
    el.className = texto ? tipo : "oculto";
    el.textContent = texto || "";
  }

  // Con PIN guardado, ir directo a caja (ella valida y, si el PIN no sirve, regresa aquí).
  if (leerPin()) {
    location.replace("caja/");
    return;
  }

  var form = $("form-codigo");
  var input = $("codigo");
  var btn = $("btn-entrar");
  var msg = $("msg");

  form.addEventListener("submit", function (ev) {
    ev.preventDefault();
    var pin = input.value.trim();
    if (!pin) { mensaje(msg, "Escribe el código de tu negocio.", "error"); return; }
    btn.disabled = true;
    mensaje(msg, "Revisando…", "aviso");
    Q.rpc("entrar", { p_pin: pin }).then(function (r) {
      btn.disabled = false;
      if (r.ok) {
        guardarPin(pin);
        location.replace("caja/");
        return;
      }
      mensaje(msg, Q.msg(r.error), "error");
    });
  });

  if (hayTarjeta()) $("ver-tarjeta").classList.remove("oculto");
})();
