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
    $("texto").textContent = "Llevas " + llenos + " de " + meta + ". El " + (meta + 1) + ".º va por la casa";
    saldo = r.sellos;
    premioListo = !!r.premio_listo;
    $("btn-premio").classList.toggle("oculto", !premioListo || canjeActivo);
    $("sin-tarjeta").classList.add("oculto");
    $("tarjeta").classList.remove("oculto");
  }

  function cargarTarjeta(id) {
    Q.rpc("tarjeta", { p_tarjeta: id }).then(function (r) {
      if (r.ok) return pintar(r);
      if (r.error === "tarjeta_invalida") {
        tarjetaId = "";
        borrar();
        mostrarSinTarjeta();
      }
      aviso(Q.msg(r.error), "error");
    });
  }

  // Al escanear: reclamar el sello. La URL se limpia después para que recargar no lo repita.
  function reclamarSello(codigo) {
    Q.rpc("reclamar", { p_codigo: codigo, p_tarjeta: tarjetaId || null }).then(function (r) {
      history.replaceState(null, "", location.pathname + location.search);
      if (r.ok) {
        tarjetaId = r.tarjeta_id;
        guardar(tarjetaId);
        var texto = r.repetido ? "Este sello ya estaba agregado" : "¡Sello agregado en " + r.cafeteria + "!";
        if (r.nueva) texto = "Creamos tu tarjeta. " + texto;
        aviso(texto, "aviso");
        pintar(r);
        return;
      }
      aviso(Q.msg(r.error), "error");
      if (tarjetaId) cargarTarjeta(tarjetaId);
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
      if (r.sellos < saldoAlCanje) terminarCanje("¡Listo! Disfruta tu postre", "aviso");
    });
  }

  function terminarCanje(texto, tipo) {
    canjeActivo = false;
    detenerTimersCanje();
    $("bloque-canje").classList.add("oculto");
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
    var codigo = location.hash.slice(1);
    if (codigo) return reclamarSello(codigo);
    if (tarjetaId) return cargarTarjeta(tarjetaId);
    mostrarSinTarjeta();
  }

  // Escanear otro QR con esta página ya abierta solo cambia el hash (no recarga).
  window.addEventListener("hashchange", function () {
    if (location.hash.length > 1) iniciar();
  });

  iniciar();
})();
