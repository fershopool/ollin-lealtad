// Tarjeta del cliente. El id de la tarjeta vive en localStorage; el código de venta llega en el hash.
// Una tarjeta acumula sellos por programa ("q" o id de cafetería); el programa activo se recuerda.
(function () {
  "use strict";

  var CLAVE = "quetzalito.tarjeta";
  var CLAVE_PROGRAMA = "quetzalito.programa";
  var CLAVE_PROGRAMAS = "quetzalito.programas";
  var MAX_PROGRAMAS = 10;
  var RE_PROGRAMA = /^[A-Za-z0-9_-]{1,64}$/;
  var RE_COLOR = /^#[0-9a-fA-F]{6}$/;
  var COLORES_FIESTA = ["#E4007C", "#C6FF7A", "#1FB67A", "#4DB5FF"];
  var $ = function (id) { return document.getElementById(id); };

  var tarjetaId = "";
  var programa = "q";   // programa activo
  var config = {};      // config del programa activo
  var nombres = {};     // clave de programa → nombre (para las fichas)
  var progreso = {};    // clave de programa → {sellos, meta, color, logo, nombre} (para el mazo de tarjetas)
  var premioListo = false;
  var canjeActivo = false;
  var canjeFin = 0;
  var saldo = 0;        // último saldo recibido
  var saldoAlCanje = 0; // saldo al pedir el código: si baja, el canje se usó
  var timerSaldo = null;
  var timerCuenta = null;
  var timerAviso = null;
  var timerSalir = null;
  var reiniciando = false; // corre la animación de reinicio tras un canje
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

  function programaValido(p) {
    return typeof p === "string" && RE_PROGRAMA.test(p) ? p : "";
  }
  function leerPrograma() {
    try { return programaValido(localStorage.getItem(CLAVE_PROGRAMA)) || "q"; } catch (e) { return "q"; }
  }
  function leerProgramas() {
    try {
      var lista = JSON.parse(localStorage.getItem(CLAVE_PROGRAMAS) || "[]");
      var out = [];
      if (!Array.isArray(lista)) return out;
      for (var i = 0; i < lista.length; i++) {
        var k = programaValido(lista[i]);
        if (k && out.indexOf(k) < 0) out.push(k);
      }
      return out;
    } catch (e) { return []; }
  }
  // Fija el programa activo y lo agrega a la lista (sin repetir; máximo 10, se olvida el más antiguo).
  function recordarPrograma(p) {
    programa = programaValido(p) || "q";
    var lista = leerProgramas();
    if (lista.indexOf(programa) < 0) lista.push(programa);
    while (lista.length > MAX_PROGRAMAS) lista.shift();
    try {
      localStorage.setItem(CLAVE_PROGRAMA, programa);
      localStorage.setItem(CLAVE_PROGRAMAS, JSON.stringify(lista));
    } catch (e) { /* sin almacenamiento: el programa vale solo en esta vista */ }
  }

  // Aviso flotante: se desvanece solo (4 s; los errores, 6 s).
  function aviso(texto, tipo) {
    var el = $("estado");
    clearTimeout(timerAviso);
    clearTimeout(timerSalir);
    el.classList.remove("salir");
    el.className = texto ? tipo : "oculto";
    el.textContent = texto || "";
    if (!texto) return;
    timerAviso = setTimeout(function () {
      el.classList.add("salir");
      timerSalir = setTimeout(function () { el.className = "oculto"; }, 320);
    }, /error/.test(tipo) ? 6000 : 4000);
  }

  function mmss(segundos) {
    var m = Math.floor(segundos / 60);
    var s = segundos % 60;
    return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
  }

  function mostrarSinTarjeta() {
    $("sin-tarjeta").classList.remove("oculto");
    $("tarjeta").classList.add("oculto");
    $("btn-recomendar").classList.add("oculto");
  }

  // Color y logo del programa; sin valores válidos, los de la página. Con tema que trae acento, manda el tema.
  function aplicarColor(color, tema) {
    var ok = typeof color === "string" && RE_COLOR.test(color) && !(tema && RE_COLOR.test(tema.acento));
    $("tarjeta").style.background = ok ? "linear-gradient(135deg, " + color + " 0%, var(--naranja) 26%, var(--esmeralda) 62%, var(--azul-neon) 100%)" : "";
    $("btn-premio").style.background = ok ? "linear-gradient(135deg, " + color + " 0%, var(--naranja-osc) 100%)" : "";
    // Aro del medallón con el color del programa (c.css usa --acento); vacío = colores de la página o del tema.
    $("logo").parentNode.style.setProperty("--acento", ok ? color : "");
  }
  // Foto del negocio en círculo lleno; Quetzalitos conserva su logo completo. Si falla, el de Quetzalitos.
  function aplicarLogo(ruta, nombre) {
    var img = $("logo");
    img.alt = nombre;
    img.onerror = null;
    img.classList.toggle("de-negocio", programa !== "q");
    img.src = Q.logo(ruta);
    img.onerror = function () {
      this.onerror = null;
      this.classList.remove("de-negocio");
      this.src = Q.logo(null);
    };
  }

  function abreviar(clave) {
    return clave.length > 8 ? clave.slice(0, 8) + "…" : clave;
  }

  // Fichas para cambiar de programa; con un solo programa no se muestran.
  // Mazo de tarjetas: una por programa, con logo, nombre y avance. Desliza en horizontal; la activa se centra.
  function pintarFichas() {
    var cont = $("programas");
    var lista = leerProgramas();
    cont.textContent = "";
    if (lista.length < 2) return cont.classList.add("oculto");
    cont.classList.remove("oculto");
    var activa = null;
    for (var i = 0; i < lista.length; i++) {
      var k = lista[i];
      var g = progreso[k] || {};
      var b = document.createElement("button");
      b.type = "button";
      b.className = "mini" + (k === programa ? " activa" : "");
      b.style.setProperty("--i", i);
      b.setAttribute("aria-pressed", k === programa ? "true" : "false");
      b.setAttribute("aria-label", (nombres[k] || abreviar(k)) + (g.meta ? ", " + Math.min(g.sellos || 0, g.meta) + " de " + g.meta : ""));
      if (RE_COLOR.test(g.color || "")) b.style.setProperty("--tono", g.color);
      var cab = document.createElement("span");
      cab.className = "mini-cab";
      var ico = document.createElement("span");
      ico.className = "mini-ico";
      if (k === "q") {
        var img = document.createElement("img");
        img.alt = "";
        img.src = Q.logo(null);
        ico.appendChild(img);
      } else if (g.logo) {
        var im = document.createElement("img");
        im.alt = "";
        im.src = Q.logo(g.logo);
        im.onerror = function () { this.remove(); };
        ico.appendChild(im);
      } else {
        // Sin logo: iniciales del nombre, nunca un emoji.
        ico.textContent = (nombres[k] || "?").split(/\s+/).filter(function (w) { return /^[A-Za-zÁÉÍÓÚÑáéíóúñ]/.test(w); }).slice(0, 2).map(function (w) { return w.charAt(0); }).join("").toUpperCase();
        ico.classList.add("sin-logo");
      }
      var nom = document.createElement("span");
      nom.className = "mini-nom";
      nom.textContent = nombres[k] || abreviar(k);
      cab.append(ico, nom);
      var pie = document.createElement("span");
      pie.className = "mini-pie";
      var meta = g.meta || 0;
      var llenos = Math.min(g.sellos || 0, meta);
      pie.textContent = meta ? llenos + " / " + meta : "";
      var barra = document.createElement("span");
      barra.className = "mini-barra";
      var rell = document.createElement("i");
      rell.style.width = meta ? Math.round((llenos / meta) * 100) + "%" : "0%";
      barra.appendChild(rell);
      b.append(cab, barra, pie);
      b.onclick = (function (clave) { return function () { cambiarPrograma(clave); }; })(k);
      cont.appendChild(b);
      if (k === programa) activa = b;
    }
    if (activa) activa.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
  }

  // Franja de abajo: el botón de canje ocupa el lugar del contador (mismo alto, sin sumar altura).
  function actualizarFranja() {
    var mostrarBoton = premioListo && !canjeActivo;
    $("btn-premio").classList.toggle("oculto", !mostrarBoton);
    $("texto").classList.toggle("oculto", mostrarBoton);
  }

  // Sellos: columnas y tamaño que hacen caber todas las fichas en la zona (meta hasta 50).
  function ajustarSellos() {
    var zona = $("zona-sellos");
    var cont = $("sellos");
    var n = cont.children.length;
    var W = zona.clientWidth;
    var H = zona.clientHeight;
    if (!n || !W || !H) return;
    // Filas de 5 como máximo y lo más parejas posible (16 → 4×4, 11 → 4+4+3, 7 → 4+3); hasta 6 sellos, 3 por fila.
    var cols = n <= 3 ? n : (n === 4 ? 2 : (n <= 6 ? 3 : Math.ceil(n / Math.ceil(n / 5))));
    var filas = Math.ceil(n / cols);
    var hueco = Math.max(6, Math.min(12, Math.floor(Math.min(W, H) / 22)));
    var tam = Math.floor(Math.min((W - hueco * (cols - 1)) / cols, (H - hueco * (filas - 1)) / filas, 92));
    if (tam < 16) tam = 16;
    cont.style.setProperty("--cols", cols);
    cont.style.setProperty("--sello", tam + "px");
    cont.style.setProperty("--hueco", hueco + "px");
  }

  // Dibuja sellos, banda, texto y botón de premio con el estado devuelto por el servidor.
  function pintar(r) {
    config = r.config || {};
    var negocio = programa !== "q";
    // Tema del negocio; en Quetzalitos, null = diseño neón de siempre.
    var tema = negocio ? config.tema || null : null;
    Q.tema(tema);
    var emoji = programa === "q" ? null : (config.sello || null);
    var meta = Math.min(50, Math.max(1, r.meta || 1));
    var llenos = Math.min(r.sellos, meta);
    var cont = $("sellos");
    cont.textContent = "";
    for (var i = 0; i < meta; i++) {
      var s = document.createElement("span");
      s.className = (i < llenos ? "sello lleno" : "sello") + (emoji ? " con-emoji" : "");
      s.style.setProperty("--i", i);
      if (emoji) {
        var ico = document.createElement("span");
        ico.className = "ico";
        ico.textContent = emoji;
        s.appendChild(ico);
      }
      cont.appendChild(s);
    }
    premioListo = !!r.premio_listo;
    // El premio es una banda fija: se ilumina cuando el premio está listo.
    var banda = $("banda");
    banda.classList.toggle("listo", premioListo);
    banda.classList.toggle("con-emoji", negocio);
    $("banda-ico").textContent = negocio ? (config.sello || "🎁") : "";
    $("banda-ico").classList.toggle("oculto", !negocio);
    $("banda-txt").textContent = config.premio || "Tu premio";
    // Avance del premio: la capa de la banda crece con los sellos reunidos.
    $("banda-avance").style.setProperty("--f", meta ? (llenos / meta).toFixed(3) : "0");
    var faltan = meta - llenos;
    var unidad = config.unidad || "sellos";
    $("texto").textContent = premioListo ? "¡Tarjeta completa!" : "Llevas " + llenos + " de " + meta + " " + unidad + " · te " + (faltan === 1 ? "falta 1" : "faltan " + faltan);
    $("mensaje").textContent = config.mensaje || "";
    $("mensaje").classList.toggle("oculto", !config.mensaje);
    $("btn-premio").textContent = "Canjear: " + (config.premio || "tu premio");
    actualizarFranja();
    $("btn-recomendar").classList.remove("oculto");

    var nombre = config.nombre || "Tu tarjeta de sellos";
    $("titulo").textContent = nombre;
    document.title = nombre;
    if (config.nombre) nombres[programa] = config.nombre;
    progreso[programa] = { sellos: r.sellos, meta: meta, color: config.color, logo: config.logo, nombre: config.nombre };
    aplicarColor(config.color, tema);
    aplicarLogo(config.logo, nombre);

    saldo = r.sellos;
    $("sin-tarjeta").classList.add("oculto");
    $("tarjeta").classList.remove("oculto");
    pintarFichas();
    ajustarSellos();
  }

  function mostrarReintentar(visible) {
    $("btn-reintentar").classList.toggle("oculto", !visible);
  }

  // silencioso: tras un reclamo fallido no pisar su mensaje con «No encontramos tu tarjeta».
  function cargarTarjeta(id, silencioso) {
    var p = programa;
    Q.rpc("tarjeta", { p_tarjeta: id, p_programa: p }).then(function (r) {
      if (p !== programa) return; // se cambió de programa mientras llegaba la respuesta
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

  // Nombres de los demás programas recordados, para las fichas (si falla, se ve la clave abreviada).
  function pedirNombre(clave) {
    Q.rpc("tarjeta", { p_tarjeta: tarjetaId, p_programa: clave }).then(function (r) {
      if (r.ok && r.config && r.config.nombre) nombres[clave] = r.config.nombre;
      if (r.ok) { var c = r.config || {}; progreso[clave] = { sellos: r.sellos, meta: Math.min(50, Math.max(1, r.meta || 1)), color: c.color, logo: c.logo, nombre: c.nombre }; }
      pintarFichas();
    });
  }
  function cargarNombres() {
    if (!tarjetaId) return;
    var lista = leerProgramas();
    for (var i = 0; i < lista.length; i++) {
      if (lista[i] !== programa) pedirNombre(lista[i]); // refresca nombre y avance de cada tarjeta
    }
  }

  function cambiarPrograma(clave) {
    if (clave === programa) return;
    if (canjeActivo) terminarCanje("", "");
    aviso("", "");
    recordarPrograma(clave);
    $("btn-premio").classList.add("oculto");
    premioListo = false;
    pintarFichas();
    cargarTarjeta(tarjetaId);
  }

  // Colores y emoji de la celebración: los del tema del negocio; en Quetzalitos, los neón.
  function celebrar() {
    if (!window.Fiesta) return;
    var tema = programa === "q" ? null : config.tema;
    var colores = [];
    [tema && tema.acento, tema && tema.acento2, config.color].forEach(function (c) {
      if (typeof c === "string" && RE_COLOR.test(c)) colores.push(c);
    });
    Fiesta.premioListo({
      zona: $("tarjeta"),
      emoji: programa === "q" ? null : (config.sello || null),
      colores: colores.length ? colores : COLORES_FIESTA
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
    // Etiqueta NFC: el hash trae uid=<14 hex>&ctr=<6 hex>&cmac=<16 hex>; el QR de caja trae solo el código.
    var nfc = /^uid=([0-9a-f]{14})&ctr=([0-9a-f]{6})&cmac=([0-9a-f]{16})$/i.exec(codigo);
    (nfc ? Q.rpc("reclamar_nfc", { p_uid: nfc[1], p_ctr: nfc[2], p_cmac: nfc[3], p_tarjeta: tarjetaId })
         : Q.rpc("reclamar", { p_codigo: codigo, p_tarjeta: tarjetaId })).then(function (r) {
      reclamando = false;
      if (r.ok) {
        history.replaceState(null, "", location.pathname + location.search);
        tarjetaId = r.tarjeta_id;
        guardar(tarjetaId);
        if (canjeActivo && r.programa !== programa) terminarCanje("", "");
        // Premio recién listo: solo si antes no lo estaba en este mismo programa.
        var estabaLista = premioListo && r.programa === programa;
        recordarPrograma(r.programa);
        var texto = r.repetido ? "Este sello ya estaba agregado" : "¡Sello agregado en " + r.cafeteria + "!";
        if (r.nueva) texto = "Creamos tu tarjeta. " + texto;
        aviso(texto, "aviso");
        pintar(r);
        cargarNombres();
        if (!r.repetido) {
          // El sello recién ganado entra con animación; los demás no se repiten al repintar.
          var llenos = $("sellos").querySelectorAll(".sello.lleno");
          if (llenos.length) llenos[llenos.length - 1].classList.add("nuevo");
        }
        if (r.premio_listo && !estabaLista) celebrar();
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
    var p = programa;
    btn.disabled = true;
    aviso("", "");
    Q.rpc("pedir_canje", { p_tarjeta: tarjetaId, p_programa: p }).then(function (r) {
      btn.disabled = false;
      if (p !== programa) return; // se cambió de programa mientras se pedía el código
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
    // La placa reemplaza a los sellos dentro de la misma zona: la altura no cambia.
    $("sellos").classList.add("oculto");
    $("bloque-canje").classList.remove("oculto");
    actualizarFranja();
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
    var p = programa;
    Q.rpc("tarjeta", { p_tarjeta: tarjetaId, p_programa: p }).then(function (r) {
      if (!canjeActivo || reiniciando || !r.ok || p !== programa) return;
      if (r.sellos < saldoAlCanje) return usarCanje(r);
      pintar(r);
    });
  }

  // Tarjeta reiniciada: animación de recarga y, al terminar, el aviso «¡Listo!».
  function usarCanje(r) {
    reiniciando = true;
    detenerTimersCanje();
    var main = document.querySelector("main");
    var repintada = false;
    var repintar = function () {
      if (repintada) return;
      repintada = true;
      pintar(r);
      var fichas = $("sellos").children;
      for (var i = 0; i < fichas.length; i++) fichas[i].classList.add("reinicio");
    };
    var fin = function () {
      repintar();
      main.style.pointerEvents = "";
      reiniciando = false;
      terminarCanje("¡Listo! Disfruta tu premio", "aviso fiesta");
    };
    if (!window.Fiesta) return fin();
    main.style.pointerEvents = "none";
    Fiesta.recargar({
      zona: document.body,
      quetzalcoatl: programa === "q",
      emoji: programa === "q" ? null : (config.sello || null),
      enMedio: repintar,
      alTerminar: fin
    });
  }

  function terminarCanje(texto, tipo) {
    canjeActivo = false;
    detenerTimersCanje();
    $("bloque-canje").classList.add("oculto");
    $("sellos").classList.remove("oculto");
    $("barra-canje").classList.remove("corre");
    $("codigo-canje").textContent = "";
    actualizarFranja();
    aviso(texto, tipo);
  }

  function detenerTimersCanje() {
    if (timerSaldo) clearInterval(timerSaldo);
    if (timerCuenta) clearInterval(timerCuenta);
    timerSaldo = null;
    timerCuenta = null;
  }


  // Recomendar: el enlace lleva el código de tu tarjeta; quien lo abre queda ligado a ti (sin sellos hasta su primera compra).
  function registrarAmigo(codigo) {
    if (!tarjetaId) { tarjetaId = nuevoId(); guardar(tarjetaId); }
    var id = tarjetaId;
    Q.rpc("registrar_referido", { p_codigo: codigo, p_tarjeta: id }).then(function (r) {
      if (r.error === "red") { mostrarReintentar(true); return aviso(Q.msg(r.error), "error"); }
      history.replaceState(null, "", location.pathname + location.search);
      if (r.ok) aviso("¡Listo! Haz tu primera compra y tu amigo gana sellos.", "aviso");
      else aviso(Q.msg(r.error), "error");
      cargarTarjeta(id, true);
    });
  }

  function hojaRecomendar(visible) {
    $("hoja-rec").classList.toggle("oculto", !visible);
    if (visible) $("btn-compartir").focus();
  }
  function pintarQrRec(texto) {
    var el = $("qr-rec");
    el.textContent = "";
    if (typeof qrcode !== "function") return;
    var qr = qrcode(0, "M");
    qr.addData(texto);
    qr.make();
    el.innerHTML = qr.createSvgTag({ cellSize: 6, margin: 4, scalable: true });
  }
  function abrirRecomendar() {
    if (!tarjetaId) return;
    Q.rpc("codigo_recomendacion", { p_tarjeta: tarjetaId }).then(function (r) {
      if (!r.ok) return aviso(Q.msg(r.error), "error");
      var enlace = location.origin + location.pathname + "#ref=" + r.codigo;
      $("enlace-rec").textContent = enlace;
      pintarQrRec(enlace);
      hojaRecomendar(true);
    });
  }
  $("btn-recomendar").addEventListener("click", abrirRecomendar);
  document.querySelectorAll("#hoja-rec [data-cerrar]").forEach(function (el) {
    el.addEventListener("click", function () { hojaRecomendar(false); });
  });
  $("btn-compartir").addEventListener("click", function () {
    var enlace = $("enlace-rec").textContent;
    if (navigator.share) return navigator.share({ title: "Tarjeta de sellos", text: "Únete a mi tarjeta de sellos", url: enlace }).catch(function () {});
    if (navigator.clipboard) navigator.clipboard.writeText(enlace).then(function () { aviso("Enlace copiado", "aviso"); }, function () {});
  });


  // ---- Avisos del celular (opcionales) y bienvenida en iPhone ----
  var CLAVE_BIENVENIDA = "quetzalito.bienvenida";
  var CLAVE_AVISOS = "quetzalito.avisos";
  function marcado(clave) { try { return localStorage.getItem(clave) === "1"; } catch (e) { return false; } }
  function marcar(clave) { try { localStorage.setItem(clave, "1"); } catch (e) { /* sin almacenamiento: volverá a preguntar */ } }
  function esIphone() {
    return /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  }
  function enInicio() {
    return (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || navigator.standalone === true;
  }
  function avisosPosibles() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && !!(window.QUETZALITO && QUETZALITO.vapid);
  }
  // Clave pública VAPID (base64url) → bytes.
  function bytesDeClave(b64u) {
    var b = atob(b64u.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((b64u.length + 3) % 4));
    var out = new Uint8Array(b.length);
    for (var i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
    return out;
  }
  // Pide permiso, registra el service worker, se suscribe y guarda la suscripción en la tarjeta.
  // Debe llamarse desde un toque del usuario (iOS lo exige).
  function suscribirAvisos() {
    if (!avisosPosibles()) return Promise.reject(new Error("no_soportado"));
    if (!tarjetaId) { tarjetaId = nuevoId(); guardar(tarjetaId); }
    var id = tarjetaId;
    return Notification.requestPermission().then(function (perm) {
      if (perm !== "granted") throw new Error("denegado");
      return navigator.serviceWorker.register("sw.js");
    }).then(function (reg) {
      return reg.pushManager.getSubscription().then(function (s) {
        return s || reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytesDeClave(QUETZALITO.vapid) });
      });
    }).then(function (sub) {
      var j = sub.toJSON();
      return Q.rpc("suscribir_aviso", { p_tarjeta: id, p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
    }).then(function (r) {
      if (!r.ok) throw new Error(r.error);
      marcar(CLAVE_AVISOS);
      return r;
    });
  }
  function actualizarBotonAvisos() {
    var mostrar = avisosPosibles() && !(esIphone() && !enInicio()) && Notification.permission !== "granted";
    $("btn-avisos").classList.toggle("oculto", !mostrar);
  }
  function mostrarBienvenida(paso) {
    $("sin-tarjeta").classList.add("oculto");
    $("tarjeta").classList.add("oculto");
    $("bienvenida").classList.remove("oculto");
    $("bien-paso-1").classList.toggle("oculto", paso !== 1);
    $("bien-paso-2").classList.toggle("oculto", paso !== 2);
    $("bien-msg").textContent = "";
  }
  function ocultarBienvenida() { $("bienvenida").classList.add("oculto"); }
  // Tras la bienvenida, la tarjeta (nueva o existente) reaparece.
  function seguirTrasBienvenida() { marcar(CLAVE_BIENVENIDA); marcar(CLAVE_AVISOS); iniciar(); }

  $("btn-avisos").addEventListener("click", function () {
    suscribirAvisos().then(function () {
      aviso("Listo: recibirás los avisos de tu tarjeta.", "aviso");
      actualizarBotonAvisos();
    }, function (err) {
      aviso(err.message === "denegado" ? "No se activaron los avisos. Puedes intentarlo otra vez." : "Este navegador no permite avisos.", "error");
    });
  });
  $("bien-listo-1").addEventListener("click", function () {
    marcar(CLAVE_BIENVENIDA);
    $("bien-paso-1").classList.add("oculto");
    $("bien-paso-2").classList.remove("oculto");
  });
  $("bien-saltar-1").addEventListener("click", function () { marcar(CLAVE_BIENVENIDA); iniciar(); });
  $("bien-saltar-2").addEventListener("click", seguirTrasBienvenida);
  $("bien-avisos").addEventListener("click", function () {
    var msg = $("bien-msg");
    msg.textContent = "Activando…";
    suscribirAvisos().then(seguirTrasBienvenida, function (err) {
      msg.textContent = err.message === "denegado"
        ? "No se activaron los avisos. Puedes activarlos después desde tu tarjeta."
        : "Este navegador no permite avisos. Tu tarjeta sigue funcionando.";
      marcar(CLAVE_AVISOS);
      setTimeout(seguirTrasBienvenida, 1600);
    });
  });

  // El service worker se registra en cuanto la página lo permite (no bloquea la tarjeta si falla).
  if (avisosPosibles()) navigator.serviceWorker.register("sw.js").catch(function () {});

  function iniciar() {
    if (!storageDisponible()) {
      aviso("Tu navegador no permite guardar datos. No podremos recordar tu tarjeta en este teléfono.", "error");
    }
    tarjetaId = leer();
    programa = leerPrograma();
    // Quien ya tiene tarjeta no debe leer «Escanea el QR…» mientras carga.
    if (tarjetaId) $("sin-tarjeta").classList.add("oculto");
    var h = location.hash.slice(1);
    if (h.indexOf("ref=") === 0) return registrarAmigo(h.slice(4));
    if (h) return reclamarSello(h);
    // iPhone sin tarjeta: primero agregar a la pantalla de inicio y luego activar avisos; después, la tarjeta nueva.
    if (!tarjetaId && esIphone() && !enInicio() && !marcado(CLAVE_BIENVENIDA)) return mostrarBienvenida(1);
    if (!tarjetaId && esIphone() && enInicio() && !marcado(CLAVE_AVISOS)) return mostrarBienvenida(2);
    ocultarBienvenida();
    actualizarBotonAvisos();
    if (tarjetaId) {
      cargarTarjeta(tarjetaId);
      return cargarNombres();
    }
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

  // Los sellos se reajustan con cada cambio de tamaño, de orientación y al cargar las fuentes.
  window.addEventListener("resize", ajustarSellos);
  window.addEventListener("orientationchange", ajustarSellos);
  if (window.ResizeObserver) new ResizeObserver(ajustarSellos).observe($("zona-sellos"));
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(ajustarSellos);

  iniciar();
})();
