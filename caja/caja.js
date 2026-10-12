// Pantalla de la cajera. El PIN vive en sessionStorage y en memoria; nunca en el código.
(function () {
  "use strict";

  var CLAVE_PIN = "quetzalito.pin";
  var PANTALLAS = ["carga", "login", "menu", "venta", "canje", "exito"];
  var $ = function (id) { return document.getElementById(id); };

  var pinActual = "";
  var timerVenta = null;

  function leerPin() {
    try { return sessionStorage.getItem(CLAVE_PIN) || ""; } catch (e) { return ""; }
  }
  function guardarPin(pin) {
    try { sessionStorage.setItem(CLAVE_PIN, pin); } catch (e) { /* sin sessionStorage el PIN queda solo en memoria */ }
  }
  function borrarPin() {
    try { sessionStorage.removeItem(CLAVE_PIN); } catch (e) { /* nada que borrar */ }
  }

  function mostrar(id) {
    PANTALLAS.forEach(function (p) { $(p).classList.toggle("oculto", p !== id); });
  }

  // tipo: "aviso", "error" o "" (vacío oculta el mensaje)
  function mensaje(el, texto, tipo) {
    el.className = texto ? tipo : "oculto";
    el.textContent = texto || "";
  }

  function mmss(segundos) {
    var m = Math.floor(segundos / 60);
    var s = segundos % 60;
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }

  function irAMenu(cafeteria) {
    $("nombre").textContent = cafeteria;
    mensaje($("menu-msg"), "", "");
    mostrar("menu");
  }

  function volverAMenu(texto, tipo) {
    detenerVenta();
    mensaje($("menu-msg"), texto, tipo || "aviso");
    mostrar("menu");
  }

  function cerrarSesion(texto) {
    pinActual = "";
    borrarPin();
    detenerVenta();
    $("pin").value = "";
    mensaje($("login-msg"), texto, "error");
    mostrar("login");
  }

  // Login
  $("form-login").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var pin = $("pin").value.trim();
    var btn = $("btn-entrar");
    if (!pin) { mensaje($("login-msg"), "Escribe el PIN.", "error"); return; }
    btn.disabled = true;
    mensaje($("login-msg"), "Revisando…", "aviso");
    Q.rpc("entrar", { p_pin: pin }).then(function (r) {
      btn.disabled = false;
      if (r.ok) {
        pinActual = pin;
        guardarPin(pin);
        $("pin").value = "";
        irAMenu(r.cafeteria);
      } else {
        mensaje($("login-msg"), Q.msg(r.error), "error");
      }
    });
  });

  // Al abrir: si hay PIN guardado, validarlo; si falla, volver al login.
  function iniciar() {
    pinActual = leerPin();
    if (!pinActual) { mostrar("login"); return; }
    mostrar("carga");
    Q.rpc("entrar", { p_pin: pinActual }).then(function (r) {
      if (r.ok) irAMenu(r.cafeteria);
      else cerrarSesion(Q.msg(r.error));
    });
  }

  $("btn-salir").addEventListener("click", function () { cerrarSesion(""); });

  // Venta de postre
  $("btn-venta").addEventListener("click", function () {
    var btn = this;
    btn.disabled = true;
    mensaje($("menu-msg"), "", "");
    Q.rpc("crear_venta", { p_pin: pinActual }).then(function (r) {
      btn.disabled = false;
      if (r.ok) return mostrarVenta(r);
      if (r.error === "pin_invalido") return cerrarSesion(Q.msg(r.error));
      mensaje($("menu-msg"), Q.msg(r.error), "error");
    });
  });

  function mostrarVenta(r) {
    var url = new URL("../c/", location.href).href + "#" + r.codigo;
    pintarQR(url);
    var fin = new Date(r.expira_en).getTime();
    mostrar("venta");
    detenerVenta();
    function tick() {
      var resta = Math.ceil((fin - Date.now()) / 1000);
      if (resta <= 0) return volverAMenu("Venció. Haz una nueva venta.", "error");
      $("cuenta").textContent = mmss(resta);
    }
    timerVenta = setInterval(tick, 1000);
    tick();
  }

  function detenerVenta() {
    if (timerVenta) clearInterval(timerVenta);
    timerVenta = null;
  }

  // Dibuja el QR; si la librería no cargó, avisa en vez de fallar en silencio.
  function pintarQR(url) {
    var el = $("qr");
    el.innerHTML = "";
    try {
      var qr = qrcode(0, "M");
      qr.addData(url);
      qr.make();
      el.innerHTML = qr.createSvgTag({ cellSize: 6, margin: 4, scalable: true });
    } catch (e) {
      el.textContent = "No se pudo generar el QR. Revisa la conexión.";
    }
  }

  $("btn-listo").addEventListener("click", function () { volverAMenu(""); });

  // Canje de premio
  $("btn-canje").addEventListener("click", function () {
    $("codigo").value = "";
    mensaje($("canje-msg"), "", "");
    mostrar("canje");
    $("codigo").focus();
  });

  $("btn-volver-canje").addEventListener("click", function () { volverAMenu(""); });

  $("btn-validar").addEventListener("click", function () {
    var codigo = $("codigo").value.trim();
    var btn = this;
    if (!/^\d{6}$/.test(codigo)) {
      mensaje($("canje-msg"), "Escribe los 6 dígitos del código.", "error");
      return;
    }
    btn.disabled = true;
    Q.rpc("canjear", { p_pin: pinActual, p_codigo: codigo }).then(function (r) {
      btn.disabled = false;
      if (r.ok) {
        $("codigo").value = "";
        return mostrar("exito");
      }
      if (r.error === "pin_invalido") return cerrarSesion(Q.msg(r.error));
      mensaje($("canje-msg"), Q.msg(r.error), "error");
    });
  });

  $("btn-nuevo").addEventListener("click", function () { volverAMenu(""); });

  iniciar();
})();
