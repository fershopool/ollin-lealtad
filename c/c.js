// Tarjeta del cliente. El id de la tarjeta vive en localStorage; el código de venta llega en el hash.
(function () {
  "use strict";

  var CLAVE = "quetzalito.tarjeta";
  var $ = function (id) { return document.getElementById(id); };

  var tarjetaId = "";
  var premioListo = false;
  var canjeActivo = false;
  var canjeFin = 0;
  var saldo = 0;        // último saldo recibido
  var saldoAlCanje = 0; // saldo al pedir el código: si baja, el canje se usó
  var timerSaldo = null;
  var timerCuenta = null;
  var reclamando = false; // hay un reclamo en curso: se ignora otro
  var generada = false;   // el id de tarjeta se creó en el reclamo en curso

  // uuid v4 con crypto.getRandomValues (crypto.randomUUID no existe sin HTTPS).
  function nuevoId() {
    var b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = "";
    for (var i = 0; i < 16; i++) h += (b[i] + 0x100).toString(16).slice(1);
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  }

  function storageDisponible() {
    try {
      localStorage.setItem(CLAVE + ".prueba", "1");
      localStorage.removeItem(CLAVE + ".prueba");
      return true;
    } catch (e) {
      return false;
    }
  }
  function leer() {
    // Un valor que no sea uuid (storage alterado) se ignora: el servidor lo rechazaría con HTTP 400.
    try {
      var id = localStorage.getItem(CLAVE) || "";
      return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id) ? id : "";
    } catch (e) { return ""; }
  }
  function guardar(id) {
    try { localStorage.setItem(CLAVE, id); } catch (e) { /* sin almacenamiento: se avisa al inicio */ }
  }
  function borrar() {
    try { localStorage.removeItem(CLAVE); } catch (e) { /* nada que borrar */ }
  }

  function aviso(texto, tipo) {
    var el = $("estado");
    el.className = texto ? tipo : "oculto";
    el.textContent = texto || "";
  }

  function mmss(segundos) {
    var m = Math.floor(segundos / 60);
    var s = segundos % 60;
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }

  function mostrarSinTarjeta() {
    $("sin-tarjeta").classList.remove("oculto");
    $("tarjeta").classList.add("oculto");
  }

  // Dibuja sellos, texto y botón de premio con el estado devuelto por el servidor.
  function pintar(r) {
    var meta = r.meta || 6;
    var llenos = Math.min(r.sellos, meta);
    var cont = $("sellos");
    cont.textContent = "";
    for (var i = 0; i < meta; i++) {
      var s = document.createElement("span");
      s.className = i < llenos ? "sello lleno" : "sello";
      cont.appendChild(s);
    }
    premioListo = !!r.premio_listo;
    // El postre gratis es el último «sello»: una banda que se ilumina cuando el premio está listo.
    var p = document.createElement("span");
    p.className = premioListo ? "sello premio listo" : "sello premio";
    p.textContent = "El " + (meta + 1) + ".º va por la casa";
    cont.appendChild(p);
    var faltan = meta - llenos;
    $("texto").textContent = premioListo ? "¡Tarjeta completa!" : "Llevas " + llenos + " de " + meta + " · te " + (faltan === 1 ? "falta 1" : "faltan " + faltan);
    saldo = r.sellos;
    $("btn-premio").classList.toggle("oculto", !premioListo || canjeActivo);
    $("sin-tarjeta").classList.add("oculto");
    $("tarjeta").classList.remove("oculto");
  }

  function mostrarReintentar(visible) {
    $("btn-reintentar").classList.toggle("oculto", !visible);
  }

  // silencioso: tras un reclamo fallido no pisar su mensaje con «No encontramos tu tarjeta».
  function cargarTarjeta(id, silencioso) {
    Q.rpc("tarjeta", { p_tarjeta: id }).then(function (r) {
      if (r.ok) return pintar(r);
      if (r.error === "tarjeta_invalida") {
        tarjetaId = "";
        borrar();
        mostrarSinTarjeta();
        if (silencioso) return;
      }
      if (r.error === "red") mostrarReintentar(true);
      aviso(Q.msg(r.error), "error");
    });
  }

  // Al escanear: reclamar el sello. El hash se quita solo cuando el servidor respondió (no con error de red),
  // para que recargar o Reintentar repitan el mismo reclamo.
  function reclamarSello(codigo) {
    if (reclamando) return;
    reclamando = true;
    generada = !tarjetaId;
    if (generada) {
      // Se guarda antes de llamar: si la respuesta se pierde, el reintento usa el mismo id.
      tarjetaId = nuevoId();
      guardar(tarjetaId);
    }
    Q.rpc("reclamar", { p_codigo: codigo, p_tarjeta: tarjetaId }).then(function (r) {
      reclamando = false;
      if (r.ok) {
        history.replaceState(null, "", location.pathname + location.search);
        tarjetaId = r.tarjeta_id;
        guardar(tarjetaId);
        var texto = r.repetido ? "Este sello ya estaba agregado" : "¡Sello agregado en " + r.cafeteria + "!";
        if (r.nueva) texto = "Creamos tu tarjeta. " + texto;
        aviso(texto, "aviso");
        pintar(r);
        if (!r.repetido) {
          // El sello recién ganado entra con animación; los demás no se repiten al repintar.
          var llenos = $("sellos").querySelectorAll(".sello.lleno");
          if (llenos.length) llenos[llenos.length - 1].classList.add("nuevo");
        }
        return;
      }
      if (r.error === "red") {
        $("sin-tarjeta").classList.add("oculto");
        mostrarReintentar(true);
        aviso(Q.msg(r.error), "error");
        return;
      }
      history.replaceState(null, "", location.pathname + location.search);
      aviso(Q.msg(r.error), "error");
      if (generada) {
        // El servidor rechazó el QR con una tarjeta recién creada aquí: no la conservamos.
        tarjetaId = "";
        borrar();
        mostrarSinTarjeta();
      } else if (tarjetaId) {
        cargarTarjeta(tarjetaId, true);
      }
    });
  }

  // Premio: pedir código de canje y consultar el saldo mientras se muestra.
  $("btn-premio").addEventListener("click", function () {
    var btn = this;
    btn.disabled = true;
    aviso("", "");
    Q.rpc("pedir_canje", { p_tarjeta: tarjetaId }).then(function (r) {
      btn.disabled = false;
      if (r.ok) return mostrarCanje(r);
      if (r.error === "tarjeta_invalida") {
        tarjetaId = "";
        borrar();
        mostrarSinTarjeta();
      }
      aviso(Q.msg(r.error), "error");
    });
  });

  function mostrarCanje(r) {
    canjeActivo = true;
    saldoAlCanje = saldo;
    canjeFin = new Date(r.expira_en).getTime();
    $("codigo-canje").textContent = r.codigo;
    $("bloque-canje").classList.remove("oculto");
    $("btn-premio").classList.add("oculto");
    // La barra se vacía en el tiempo que le queda al código.
    var barra = $("barra-canje");
    barra.classList.remove("corre");
    void barra.offsetWidth;
    barra.style.animationDuration = Math.max(canjeFin - Date.now(), 0) + "ms";
    barra.classList.add("corre");
    detenerTimersCanje();
    timerSaldo = setInterval(consultarSaldo, 5000);
    timerCuenta = setInterval(tickCanje, 1000);
    tickCanje();
  }

  function tickCanje() {
    var resta = Math.ceil((canjeFin - Date.now()) / 1000);
    if (resta <= 0) {
      return terminarCanje("El código venció. Toca el botón si quieres otro.", "aviso");
    }
    $("cuenta-canje").textContent = "Vence en " + mmss(resta);
  }

  // Si el saldo baja respecto al que había al pedir el código, el canje ya se usó en la caja.
  function consultarSaldo() {
    Q.rpc("tarjeta", { p_tarjeta: tarjetaId }).then(function (r) {
      if (!canjeActivo || !r.ok) return;
      pintar(r);
      if (r.sellos < saldoAlCanje) terminarCanje("¡Listo! Disfruta tu postre", "aviso fiesta");
    });
  }

  function terminarCanje(texto, tipo) {
    canjeActivo = false;
    detenerTimersCanje();
    $("bloque-canje").classList.add("oculto");
    $("barra-canje").classList.remove("corre");
    $("codigo-canje").textContent = "";
    $("btn-premio").classList.toggle("oculto", !premioListo);
    aviso(texto, tipo);
  }

  function detenerTimersCanje() {
    if (timerSaldo) clearInterval(timerSaldo);
    if (timerCuenta) clearInterval(timerCuenta);
    timerSaldo = null;
    timerCuenta = null;
  }

  function iniciar() {
    if (!storageDisponible()) {
      aviso("Tu navegador no permite guardar datos. No podremos recordar tu tarjeta en este teléfono.", "error");
    }
    tarjetaId = leer();
    // Quien ya tiene tarjeta no debe leer «Escanea el QR…» mientras carga.
    if (tarjetaId) $("sin-tarjeta").classList.add("oculto");
    var codigo = location.hash.slice(1);
    if (codigo) return reclamarSello(codigo);
    if (tarjetaId) return cargarTarjeta(tarjetaId);
    mostrarSinTarjeta();
  }

  // Escanear otro QR con esta página ya abierta solo cambia el hash (no recarga).
  window.addEventListener("hashchange", function () {
    if (location.hash.length > 1) iniciar();
  });

  $("btn-reintentar").addEventListener("click", function () {
    this.classList.add("oculto");
    aviso("", "");
    iniciar();
  });

  iniciar();
})();
