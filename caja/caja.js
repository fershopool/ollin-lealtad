// Pantalla de caja. El PIN vive en sessionStorage y en memoria; nunca en el código.
(function () {
  "use strict";

  var CLAVE_PIN = "quetzalito.pin";
  var PANTALLAS = ["carga", "menu", "venta", "canje", "exito"];
  var $ = function (id) { return document.getElementById(id); };

  var pinActual = "";
  var timerVenta = null;
  var codigoVenta = "";
  var logoNegocio = null; // r.logo de entrar; sirve de logo central del QR propio

  function leerPin() {
    try { return sessionStorage.getItem(CLAVE_PIN) || ""; } catch (e) { return ""; }
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

  // Emoji del tema como ícono del botón (textContent, nunca innerHTML). Sin emoji quita el de un entrar anterior.
  function ponerEmoji(boton, emoji) {
    var viejo = boton.querySelector(".emoji");
    if (viejo) boton.removeChild(viejo);
    boton.classList.remove("con-emoji");
    if (typeof emoji !== "string" || !emoji) return;
    var span = document.createElement("span");
    span.className = "emoji";
    span.setAttribute("aria-hidden", "true");
    span.textContent = emoji;
    boton.insertBefore(span, boton.firstChild);
    boton.classList.add("con-emoji");
  }

  // r: respuesta completa de entrar (cafeteria, escuela, tipo, logo, color, distribuidor, admin, tema).
  function irAMenu(r) {
    var logo = $("logo-negocio");
    var admin = r.admin === true;
    var distribuidor = r.distribuidor === true;
    var tema = r.tema || null;
    Q.tema(tema);
    ponerEmoji($("btn-venta"), tema && tema.emoji_venta);
    ponerEmoji($("btn-canje"), tema && tema.emoji_canje);
    ponerEmoji($("btn-panel"), tema && tema.emoji_panel);
    logo.onerror = function () { logo.onerror = null; logo.src = Q.logo(null); };
    logo.src = Q.logo(r.logo);
    logoNegocio = r.logo;
    $("nombre").textContent = r.cafeteria;
    $("tipo").textContent = Q.subtitulo(r.tipo || "Cafetería", r.escuela);
    $("tipo").style.color = typeof r.color === "string" && /^#[0-9a-fA-F]{6}$/.test(r.color) ? r.color : "";
    $("btn-venta").classList.toggle("oculto", admin);
    $("btn-venta-q").classList.toggle("oculto", admin || !distribuidor);
    $("btn-canje").classList.toggle("oculto", admin);
    $("btn-panel").classList.toggle("oculto", admin);
    $("btn-control").classList.toggle("oculto", !admin);
    mensaje($("menu-msg"), "", "");
    mostrar("menu");
  }

  function volverAMenu(texto, tipo) {
    detenerVenta();
    mensaje($("menu-msg"), texto, tipo || "aviso");
    mostrar("menu");
  }

  // Sin PIN o PIN inválido: borra lo guardado y regresa a la pantalla de entrada.
  function cerrarSesion() {
    pinActual = "";
    borrarPin();
    detenerVenta();
    location.replace("../");
  }

  // Al abrir: si hay PIN guardado, validarlo. Solo un PIN incorrecto borra el guardado;
  // con red o bloqueo se conserva y se ofrece Reintentar.
  function iniciar() {
    pinActual = leerPin();
    if (!pinActual) return cerrarSesion();
    mostrar("carga");
    Q.rpc("entrar", { p_pin: pinActual }).then(function (r) {
      if (r.ok) return irAMenu(r);
      if (r.error === "pin_invalido") return cerrarSesion();
      $("carga-verificando").classList.add("oculto");
      mensaje($("carga-msg"), Q.msg(r.error), "error");
      $("btn-reintentar").classList.remove("oculto");
    });
  }

  $("btn-reintentar").addEventListener("click", function () {
    this.classList.add("oculto");
    mensaje($("carga-msg"), "", "");
    $("carga-verificando").classList.remove("oculto");
    iniciar();
  });

  $("btn-salir").addEventListener("click", function () { cerrarSesion(); });

  // Panel administrativo: página aparte; el PIN sigue en sessionStorage.
  $("btn-panel").addEventListener("click", function () { location.href = "../negocio/"; });

  // Super admin: panel de control aparte; el PIN sigue en sessionStorage.
  $("btn-control").addEventListener("click", function () { location.href = "../panel/"; });

  // Venta: quetzalitos true = QR del programa Quetzalitos (solo distribuidores); false = propio.
  function pedirVenta(btn, quetzalitos) {
    btn.disabled = true;
    mensaje($("menu-msg"), "", "");
    Q.rpc("crear_venta", { p_pin: pinActual, p_quetzalitos: quetzalitos }).then(function (r) {
      btn.disabled = false;
      if (r.ok) return mostrarVenta(r, quetzalitos);
      if (r.error === "pin_invalido") return cerrarSesion();
      mensaje($("menu-msg"), Q.msg(r.error), "error");
    });
  }

  $("btn-venta").addEventListener("click", function () { pedirVenta(this, false); });
  $("btn-venta-q").addEventListener("click", function () { pedirVenta(this, true); });

  function mostrarVenta(r, quetzalitos) {
    var url = new URL("../c/", location.href).href + "#" + r.codigo;
    codigoVenta = r.codigo;
    $("venta-titulo").textContent = quetzalitos ? "QR Quetzalitos" : "QR de tu tarjeta";
    // Medallón: logo del negocio; sin logo propio, el de Quetzalitos (mismo que el botón).
    pintarQR(url, quetzalitos ? Q.logo("img/logo-240.png") : Q.logo(logoNegocio || "img/logo-240.png"));
    ponerBotonesVenta(true);
    mensaje($("venta-msg"), "", "");
    var fin = new Date(r.expira_en).getTime();
    mostrar("venta");
    detenerVenta();
    // Después de detenerVenta(), que quita la clase: si no, la barra nunca arrancaría.
    var barra = $("barra-venta");
    barra.classList.remove("corre");
    void barra.offsetWidth;
    barra.style.animationDuration = Math.max(fin - Date.now(), 0) + "ms";
    barra.classList.add("corre");
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
    $("barra-venta").classList.remove("corre");
  }

  // Dibuja el QR (corrección H para que el logo central no lo estropee); si la librería no cargó, avisa.
  // El logo va fuera de #qr: repintar el SVG no lo toca. Si no carga, se oculta y el QR sigue.
  function pintarQR(url, logoSrc) {
    var el = $("qr");
    var logo = $("qr-logo");
    el.innerHTML = "";
    logo.style.display = "";
    logo.src = logoSrc;
    try {
      var qr = qrcode(0, "H");
      qr.addData(url);
      qr.make();
      el.innerHTML = qr.createSvgTag({ cellSize: 6, margin: 4, scalable: true });
    } catch (e) {
      logo.style.display = "none";
      el.textContent = "No se pudo generar el QR. Revisa la conexión.";
    }
  }
  $("qr-logo").onerror = function () { this.style.display = "none"; };

  $("btn-listo").addEventListener("click", function () { volverAMenu(""); });

  // Mientras se cancela, «Listo» y «Cancelar» quedan deshabilitados para no mandar dos veces.
  function ponerBotonesVenta(activos) {
    $("btn-listo").disabled = !activos;
    $("btn-cancelar-venta").disabled = !activos;
  }

  // Cancelar venta: solo sirve si el cliente aún no escaneó el QR (token_usado).
  $("btn-cancelar-venta").addEventListener("click", function () {
    mensaje($("venta-msg"), "", "");
    ponerBotonesVenta(false);
    Q.rpc("cancelar_venta", { p_pin: pinActual, p_codigo: codigoVenta }).then(function (r) {
      if (r.ok) return volverAMenu("Venta cancelada. Ese QR ya no sirve.", "aviso");
      if (r.error === "pin_invalido") return cerrarSesion();
      if (r.error === "token_usado") return volverAMenu("El cliente ya escaneó ese QR; la venta no se puede cancelar.", "error");
      ponerBotonesVenta(true);
      mensaje($("venta-msg"), Q.msg(r.error), "error");
    });
  });

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
        var premio = typeof r.premio === "string" ? r.premio.trim() : "";
        $("exito-texto").textContent = premio ? "¡Entrega: " + premio + "!" : "¡Entrega el premio!";
        return mostrar("exito");
      }
      if (r.error === "pin_invalido") return cerrarSesion();
      // Con red el canje pudo quedar registrado: se pide reintentar sin asumir que falló.
      if (r.error === "red") {
        mensaje($("canje-msg"), "No se pudo confirmar el canje. Vuelve a tocar «Validar»: si dice que ya fue usado, el canje sí quedó registrado hace un momento.", "error");
        return;
      }
      mensaje($("canje-msg"), Q.msg(r.error), "error");
    });
  });

  $("btn-nuevo").addEventListener("click", function () { volverAMenu(""); });

  iniciar();
})();
