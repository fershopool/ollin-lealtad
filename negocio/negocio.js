// Panel del negocio. El PIN vive en sessionStorage; nunca se escribe en la página.
(function () {
  "use strict";

  var CLAVE_PIN = "quetzalito.pin";
  var $ = function (id) { return document.getElementById(id); };

  var pinActual = "";
  var seq = 0; // cada carga de métricas toma un número; las respuestas viejas se descartan
  var periodoActual = "7"; // "7", "30" o "todo"

  function leerPin() {
    try { return sessionStorage.getItem(CLAVE_PIN) || ""; } catch (e) { return ""; }
  }
  function borrarPin() {
    try { sessionStorage.removeItem(CLAVE_PIN); } catch (e) { /* nada que borrar */ }
  }

  // tipo: "aviso", "error" o "" (vacío oculta el mensaje)
  function mensaje(el, texto, tipo) {
    el.className = texto && tipo ? "msg-slot " + tipo : "msg-slot";
    el.textContent = texto || "";
  }

  function salirAlInicio() {
    pinActual = "";
    borrarPin();
    location.replace("../");
  }

  function pintarMetricas(r) {
    var ventas = r.ventas || 0;
    var reclamos = r.reclamos || 0;
    var pct = ventas === 0 ? 0 : Math.min(100, Math.round(reclamos / ventas * 100));
    $("m-ventas").textContent = String(ventas);
    $("m-reclamos").textContent = String(reclamos);
    $("m-adopcion").textContent = ventas === 0 ? "—" : pct + "%";
    $("m-adopcion-barra").style.width = pct + "%";
    $("m-adopcion-track").setAttribute("aria-valuenow", String(pct));
    $("m-canjes").textContent = String(r.canjes || 0);
    $("m-tarjetas").textContent = String(r.tarjetas_nuevas || 0);
  }

  // ---- Mi tarjeta: editor de configuración con vista previa ----
  var COLOR_DEFECTO = "#1fb67a";
  var colorActual = ""; // "" = sin color propio; si no, #RRGGBB
  var nombreNegocio = "";
  var escuelaNegocio = "";
  var logoActual = ""; // logo guardado: enlace, ruta, foto (data URL) o "" = logo de Quetzalitos

  function esFoto(s) {
    return /^data:image\/(jpeg|png|webp);base64,/.test(s || "");
  }

  function logoValido(s) {
    return s === "" || (/^https:\/\/\S+$/.test(s) && s.length <= 300) || (/^img\/negocios\/\S+$/.test(s) && s.length <= 300);
  }

  function leerForm() {
    return {
      tipo: $("f-tipo").value.trim(),
      logo: $("f-logo").value.trim(),
      color: colorActual,
      meta: $("f-meta").value.trim(),
      unidad: $("f-unidad").value.trim(),
      premio: $("f-premio").value.trim(),
      mensaje: $("f-mensaje").value.trim()
    };
  }

  function validarForm(d) {
    if (d.tipo.length < 1 || d.tipo.length > 30) return "El tipo de negocio debe tener de 1 a 30 caracteres.";
    if (!logoValido(d.logo)) return "El logo debe ser un enlace https://… (hasta 300 caracteres) o una ruta img/negocios/….";
    if (d.color && !/^#[0-9a-fA-F]{6}$/.test(d.color)) return "El color no es válido.";
    if (!/^\d+$/.test(d.meta) || Number(d.meta) < 1 || Number(d.meta) > 50) return "La meta debe ser un número entero de 1 a 50.";
    if (d.unidad.length < 1 || d.unidad.length > 20) return "La palabra para lo que se junta debe tener de 1 a 20 caracteres.";
    if (d.premio.length < 1 || d.premio.length > 60) return "El premio debe tener de 1 a 60 caracteres.";
    if (d.mensaje.length > 120) return "El mensaje puede tener hasta 120 caracteres.";
    return "";
  }

  function pintarCabecera(r) {
    $("titulo").textContent = "Panel de " + nombreNegocio;
    $("subtitulo").textContent = Q.subtitulo(r.tipo || "Cafetería", escuelaNegocio);
    document.title = "Panel de " + nombreNegocio;
  }

  // Logo en cabecera y avatar del editor; el campo de enlace muestra «Foto subida» si hay foto.
  function pintarLogo() {
    var src = Q.logo(logoActual);
    $("logo").src = src;
    $("foto-avatar").src = src;
    if (esFoto(logoActual)) $("f-logo").value = "";
    $("f-logo").placeholder = esFoto(logoActual) ? "Foto subida" : "https://…";
    $("btn-quitar-foto").disabled = !logoActual;
  }

  function actualizarPrevia() {
    var d = leerForm();
    var previa = $("previa");
    var meta = parseInt(d.meta, 10);
    if (!(meta >= 1 && meta <= 50)) meta = 0;
    var acento = /^#[0-9a-fA-F]{6}$/.test(colorActual) ? colorActual : "";
    // Con foto subida y el campo vacío, la vista previa muestra la foto guardada.
    var fuente = d.logo || (esFoto(logoActual) ? logoActual : "");
    if (!esFoto(fuente) && !logoValido(fuente)) fuente = "";

    $("previa-logo").src = Q.logo(fuente);
    $("previa-nombre").textContent = nombreNegocio;
    $("previa-conteo").textContent = "0 de " + meta + " " + (d.unidad || "sellos");
    var circulos = $("previa-circulos");
    circulos.textContent = "";
    for (var i = 0; i < meta; i++) {
      var c = document.createElement("span");
      c.className = "previa-circulo";
      circulos.appendChild(c);
    }
    $("previa-premio").textContent = d.premio;
    $("previa-mensaje").textContent = d.mensaje;
    if (acento) previa.style.setProperty("--acento", acento);
    else previa.style.removeProperty("--acento");
  }

  function rellenarForm(r) {
    $("f-tipo").value = r.tipo || "";
    logoActual = r.logo || "";
    $("f-logo").value = esFoto(logoActual) ? "" : logoActual;
    colorActual = r.color || "";
    $("f-color").value = colorActual ? colorActual.toLowerCase() : COLOR_DEFECTO;
    $("f-meta").value = r.meta != null ? String(r.meta) : "";
    $("f-unidad").value = r.unidad || "";
    $("f-premio").value = r.premio || "";
    $("f-mensaje").value = r.mensaje || "";
    pintarLogo();
    actualizarPrevia();
  }

  function valorDias() {
    return periodoActual === "todo" ? null : Number(periodoActual);
  }

  function cargarMetricas() {
    var mio = ++seq;
    mensaje($("metricas-msg"), "Cargando…", "aviso");
    Q.rpc("mis_metricas", { p_pin: pinActual, p_dias: valorDias() }).then(function (r) {
      if (mio !== seq) return; // el periodo cambió mientras cargaba
      if (r.ok) {
        mensaje($("metricas-msg"), "", "");
        return pintarMetricas(r);
      }
      if (r.error === "pin_invalido") return salirAlInicio();
      mensaje($("metricas-msg"), Q.msg(r.error), "error");
    });
  }

  // ---- Secciones (una a la vez) y menú flotante ----
  var SECCIONES = ["resumen", "tarjeta", "diseno"];

  function seccionDesdeHash() {
    var h = location.hash.replace("#", "");
    return SECCIONES.indexOf(h) >= 0 ? h : "resumen";
  }

  function poner(el, clase, activo) {
    if (activo) el.classList.add(clase); else el.classList.remove(clase);
  }

  function mostrarSeccion(s) {
    SECCIONES.forEach(function (x) {
      poner($("sec-" + x), "oculto", x !== s);
      var b = $("nav-" + x);
      var on = x === s;
      poner(b, "activo", on);
      if (on) b.setAttribute("aria-current", "page");
      else b.removeAttribute("aria-current");
    });
  }

  function mostrarPanel(r) {
    nombreNegocio = r.cafeteria || "";
    escuelaNegocio = r.escuela || "";
    pintarCabecera(r);
    rellenarForm(r);
    Q.tema(r.tema);
    rellenarDiseno(r.tema);
    $("carga").classList.add("oculto");
    $("panel").classList.remove("oculto");
    $("nav").classList.remove("oculto");
    mostrarSeccion(seccionDesdeHash());
    cargarMetricas();
  }

  function mostrarCarga(texto) {
    $("panel").classList.add("oculto");
    $("carga").classList.remove("oculto");
    $("carga-verificando").classList.add("oculto");
    mensaje($("carga-msg"), texto, "error");
    $("btn-reintentar").classList.remove("oculto");
  }

  function iniciar() {
    pinActual = leerPin();
    if (!pinActual) return location.replace("../");
    $("carga-verificando").classList.remove("oculto");
    Q.rpc("entrar", { p_pin: pinActual }).then(function (r) {
      if (r.ok) return mostrarPanel(r);
      if (r.error === "pin_invalido") return salirAlInicio();
      mostrarCarga(Q.msg(r.error));
    });
  }

  // Periodo: control segmentado (7 días · 30 días · Todo)
  Array.prototype.forEach.call($("periodo").querySelectorAll(".seg-op"), function (b) {
    b.addEventListener("click", function () {
      var v = this.getAttribute("data-dias");
      if (v === periodoActual) return;
      periodoActual = v;
      Array.prototype.forEach.call($("periodo").querySelectorAll(".seg-op"), function (x) {
        x.setAttribute("aria-pressed", String(x.getAttribute("data-dias") === v));
      });
      cargarMetricas();
    });
  });

  SECCIONES.forEach(function (x) {
    $("nav-" + x).addEventListener("click", function () {
      var s = this.getAttribute("data-sec");
      location.hash = "#" + s;
      mostrarSeccion(s);
      window.scrollTo(0, 0);
    });
  });
  window.addEventListener("hashchange", function () {
    if (!$("panel").classList.contains("oculto")) mostrarSeccion(seccionDesdeHash());
  });
  $("nav-caja").addEventListener("click", function () { location.href = "../caja/"; });

  $("btn-reintentar").addEventListener("click", function () {
    this.classList.add("oculto");
    mensaje($("carga-msg"), "", "");
    $("carga-verificando").classList.remove("oculto");
    iniciar();
  });

  // Mi tarjeta: vista previa en vivo y guardado
  ["f-tipo", "f-logo", "f-meta", "f-unidad", "f-premio", "f-mensaje"].forEach(function (id) {
    $(id).addEventListener("input", actualizarPrevia);
  });
  $("f-color").addEventListener("input", function () {
    colorActual = this.value;
    actualizarPrevia();
  });
  $("btn-quitar-color").addEventListener("click", function () {
    colorActual = "";
    $("f-color").value = COLOR_DEFECTO;
    actualizarPrevia();
  });
  $("previa-logo").onerror = function () {
    this.onerror = null;
    this.src = Q.logo("");
  };

  $("form-tarjeta").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var d = leerForm();
    var err = validarForm(d);
    if (err) return mensaje($("config-msg"), err, "error");
    var boton = $("btn-guardar");
    boton.disabled = true;
    mensaje($("config-msg"), "Guardando…", "aviso");
    var args = {
      p_pin: pinActual,
      p_tipo: d.tipo,
      p_color: d.color,
      p_meta: Number(d.meta),
      p_premio: d.premio,
      p_unidad: d.unidad,
      p_mensaje: d.mensaje
    };
    // Con foto subida y el campo de enlace vacío, la foto se conserva: no se envía p_logo.
    if (!(d.logo === "" && esFoto(logoActual))) args.p_logo = d.logo;
    Q.rpc("guardar_config", args).then(function (r) {
      boton.disabled = false;
      if (r.ok) {
        rellenarForm(r);
        pintarCabecera(r);
        return mensaje($("config-msg"), "Guardado", "aviso");
      }
      if (r.error === "pin_invalido") return salirAlInicio();
      mensaje($("config-msg"), Q.msg(r.error), "error");
    });
  });

  // ---- Foto de perfil: elegir, recortar en el editor y guardar ----
  var LIMITE_ARCHIVO = 10 * 1024 * 1024;
  var lienzo = $("editor-canvas");
  var ctx = lienzo.getContext("2d");
  // modo: "perfil" (círculo 192×192) o "fondo" (rectángulo 3:4 para la pantalla)
  var ed = { img: null, modo: "perfil", rot: 0, zoom: 1, ox: 0, oy: 0, arrastra: false, x0: 0, y0: 0, ox0: 0, oy0: 0 };
  var disparador = null; // elemento que abrió el editor; recupera el foco al cerrar
  var destinoSubida = "perfil"; // a qué foto va el archivo que se elija

  // Dibuja la foto en un lienzo de W×H; «k» escala los desplazamientos (ed.ox/oy van en píxeles de la vista previa).
  function pintarEn(g, W, H, k) {
    g.fillStyle = "#FFFFFF";
    g.fillRect(0, 0, W, H);
    if (!ed.img) return;
    var im = ed.img;
    var girada = ed.rot % 2 === 1;
    var dw = girada ? im.height : im.width;
    var dh = girada ? im.width : im.height;
    var s = Math.max(W / dw, H / dh) * ed.zoom; // «ajustar» = que cubra el cuadro
    g.save();
    g.translate(W / 2 + ed.ox * k, H / 2 + ed.oy * k);
    g.rotate(ed.rot * Math.PI / 2);
    g.drawImage(im, -im.width * s / 2, -im.height * s / 2, im.width * s, im.height * s);
    g.restore();
  }

  function dibujarEditor() {
    var W = lienzo.width, H = lienzo.height;
    if (ed.img) {
      var im = ed.img;
      var girada = ed.rot % 2 === 1;
      var dw = girada ? im.height : im.width;
      var dh = girada ? im.width : im.height;
      var s = Math.max(W / dw, H / dh) * ed.zoom;
      var maxX = (dw * s - W) / 2;
      var maxY = (dh * s - H) / 2;
      ed.ox = Math.max(-maxX, Math.min(maxX, ed.ox));
      ed.oy = Math.max(-maxY, Math.min(maxY, ed.oy));
    }
    pintarEn(ctx, W, H, 1);
  }

  function abrirEditor(img, modo) {
    var fondo = modo === "fondo";
    ed.img = img; ed.modo = fondo ? "fondo" : "perfil";
    ed.rot = 0; ed.zoom = 1; ed.ox = 0; ed.oy = 0;
    lienzo.width = fondo ? 240 : 280;
    lienzo.height = fondo ? 320 : 280;
    $("editor-foto").classList.toggle("modo-fondo", fondo);
    $("editor-titulo").textContent = fondo ? "Ajusta tu foto de fondo" : "Ajusta tu foto";
    $("editor-zoom").value = "1";
    mensaje($("editor-msg"), "", "");
    $("editor-usar").disabled = false;
    disparador = document.activeElement;
    $("panel").setAttribute("aria-hidden", "true");
    $("nav").setAttribute("aria-hidden", "true");
    $("editor-foto").classList.remove("oculto");
    dibujarEditor();
    $("editor-zoom").focus();
  }

  function cerrarEditor() {
    ed.img = null;
    $("editor-foto").classList.add("oculto");
    $("panel").removeAttribute("aria-hidden");
    $("nav").removeAttribute("aria-hidden");
    if (disparador) disparador.focus();
    disparador = null;
  }

  // Recorte cuadrado de 192 px en JPEG; baja calidad o tamaño hasta caber en 55 000 caracteres.
  function generarFoto() {
    var pasos = [[192, 0.85], [192, 0.7], [192, 0.55], [160, 0.55]];
    for (var i = 0; i < pasos.length; i++) {
      var t = pasos[i][0];
      var c = document.createElement("canvas");
      c.width = t;
      c.height = t;
      var g = c.getContext("2d");
      g.fillStyle = "#FFFFFF";
      g.fillRect(0, 0, t, t);
      g.drawImage(lienzo, 0, 0, t, t);
      var url = c.toDataURL("image/jpeg", pasos[i][1]);
      if (url.length <= 55000) return url;
    }
    return "";
  }

  // Foto de fondo: 480×640 JPEG; baja calidad o tamaño hasta caber en 140 000 caracteres.
  function generarFondo() {
    var pasos = [[480, 640, 0.72], [480, 640, 0.6], [480, 640, 0.5], [360, 480, 0.5]];
    for (var i = 0; i < pasos.length; i++) {
      var c = document.createElement("canvas");
      c.width = pasos[i][0];
      c.height = pasos[i][1];
      pintarEn(c.getContext("2d"), c.width, c.height, c.width / lienzo.width);
      var url = c.toDataURL("image/jpeg", pasos[i][2]);
      if (url.length <= 140000) return url;
    }
    return "";
  }

  $("btn-subir-foto").addEventListener("click", function () { destinoSubida = "perfil"; $("foto-archivo").click(); });
  $("btn-subir-fondo").addEventListener("click", function () { destinoSubida = "fondo"; $("foto-archivo").click(); });
  $("foto-archivo").addEventListener("change", function () {
    var archivo = this.files && this.files[0];
    this.value = "";
    if (!archivo) return;
    var fondo = destinoSubida === "fondo";
    var msg = $(fondo ? "diseno-msg" : "config-msg");
    if (archivo.size > LIMITE_ARCHIVO) return mensaje(msg, "La imagen pesa más de 10 MB. Elige otra.", "error");
    var url = URL.createObjectURL(archivo);
    var img = new Image();
    img.onload = function () { URL.revokeObjectURL(url); abrirEditor(img, fondo ? "fondo" : "perfil"); };
    img.onerror = function () { URL.revokeObjectURL(url); mensaje(msg, "No pudimos leer esa imagen", "error"); };
    img.src = url;
  });

  // Arrastrar para mover (pointer events; el canvas tiene touch-action: none)
  lienzo.addEventListener("pointerdown", function (ev) {
    if (!ed.img) return;
    ed.arrastra = true;
    ed.x0 = ev.clientX; ed.y0 = ev.clientY;
    ed.ox0 = ed.ox; ed.oy0 = ed.oy;
    if (lienzo.setPointerCapture) lienzo.setPointerCapture(ev.pointerId);
  });
  lienzo.addEventListener("pointermove", function (ev) {
    if (!ed.arrastra) return;
    var k = lienzo.width / lienzo.getBoundingClientRect().width;
    ed.ox = ed.ox0 + (ev.clientX - ed.x0) * k;
    ed.oy = ed.oy0 + (ev.clientY - ed.y0) * k;
    dibujarEditor();
  });
  function soltar() { ed.arrastra = false; }
  lienzo.addEventListener("pointerup", soltar);
  lienzo.addEventListener("pointercancel", soltar);

  $("editor-zoom").addEventListener("input", function () {
    ed.zoom = parseFloat(this.value) || 1;
    dibujarEditor();
  });
  $("editor-girar").addEventListener("click", function () {
    ed.rot = (ed.rot + 1) % 4;
    ed.ox = 0; ed.oy = 0;
    dibujarEditor();
  });
  $("editor-cancelar").addEventListener("click", cerrarEditor);

  // Diálogo: Escape cierra y el foco no sale del diálogo mientras está abierto
  document.addEventListener("keydown", function (ev) {
    if ($("editor-foto").classList.contains("oculto")) return;
    if (ev.key === "Escape" || ev.key === "Esc") { ev.preventDefault(); return cerrarEditor(); }
    if (ev.key !== "Tab") return;
    var foco = [$("editor-zoom"), $("editor-girar"), $("editor-cancelar"), $("editor-usar")];
    var i = foco.indexOf(document.activeElement);
    if (ev.shiftKey && i <= 0) { ev.preventDefault(); foco[foco.length - 1].focus(); }
    else if (!ev.shiftKey && (i < 0 || i === foco.length - 1)) { ev.preventDefault(); foco[0].focus(); }
  });

  $("editor-usar").addEventListener("click", function () {
    if (ed.modo === "fondo") return usarFondo();
    var boton = this;
    var url = generarFoto();
    if (!url) return mensaje($("editor-msg"), "La foto pesa demasiado; prueba con otra", "error");
    boton.disabled = true;
    mensaje($("editor-msg"), "Guardando…", "aviso");
    Q.rpc("guardar_config", { p_pin: pinActual, p_logo: url }).then(function (r) {
      boton.disabled = false;
      if (r.ok) {
        logoActual = r.logo || url;
        cerrarEditor();
        pintarLogo();
        actualizarPrevia();
        return mensaje($("config-msg"), "Foto actualizada", "aviso");
      }
      if (r.error === "pin_invalido") return salirAlInicio();
      mensaje($("editor-msg"), r.error === "config_invalida" ? "La foto no se pudo guardar" : Q.msg(r.error), "error");
    });
  });

  $("btn-quitar-foto").addEventListener("click", function () {
    var boton = this;
    boton.disabled = true;
    mensaje($("config-msg"), "Quitando foto…", "aviso");
    Q.rpc("guardar_config", { p_pin: pinActual, p_logo: "" }).then(function (r) {
      if (r.ok) {
        logoActual = "";
        $("f-logo").value = "";
        pintarLogo();
        actualizarPrevia();
        return mensaje($("config-msg"), "Foto quitada", "aviso");
      }
      boton.disabled = !logoActual;
      if (r.error === "pin_invalido") return salirAlInicio();
      mensaje($("config-msg"), Q.msg(r.error), "error");
    });
  });

  // ---- Diseño: colores, letras, íconos e imagen de fondo, con vista previa en vivo ----
  var COLORES = ["acento", "acento2", "fondo"];
  var COLOR_ID = { acento: "dis-acento", acento2: "dis-acento2", fondo: "dis-fondo" };
  var ORIGINAL = { acento: "#e4007c", acento2: "#1f5bd6", fondo: "#0a2e22" };
  var colorDis = { acento: "", acento2: "", fondo: "" }; // "" = sin definir (se usa el original)
  var fondoFoto = ""; // foto de fondo subida (data URL), pendiente de «Guardar diseño» o ya guardada
  var ESTILOS = [
    ["Selva", "#E4007C", "#1F5BD6", "#0A2E22"],
    ["Atardecer", "#FF6B35", "#7B2CBF", "#2B0A1F"],
    ["Océano", "#00B4D8", "#3A0CA3", "#06223A"],
    ["Café", "#C97B3F", "#6F4E37", "#20130B"],
    ["Neón", "#FF2E93", "#00E5FF", "#0B0B1A"]
  ];
  var SUGERENCIAS = ["🍺", "☕", "🍕", "🍰", "🌮", "🍔", "🎟️", "⭐", "🎁", "🔑", "📊"];
  var SUG_SELLO = ["⭐", "🌮", "☕", "🍺", "🍕", "🍰", "🍔", "🎲", "🎟️", "💎", "🔥", "🌸", "🍀", "🧡"];
  var ICONOS = [
    { clave: "emoji_sello", campo: "dis-emoji-sello", sug: "sug-sello", sugs: SUG_SELLO, maq: null, defecto: "🦜" },
    { clave: "emoji_venta", campo: "dis-emoji-venta", sug: "sug-venta", maq: "dis-m-venta", defecto: "🧾" },
    { clave: "emoji_canje", campo: "dis-emoji-canje", sug: "sug-canje", maq: "dis-m-canje", defecto: "🎁" },
    { clave: "emoji_panel", campo: "dis-emoji-panel", sug: "sug-panel", maq: "dis-m-panel", defecto: "📊" }
  ];

  function hexValido(c) { return /^#[0-9a-fA-F]{6}$/.test(c || ""); }
  function imagenValida(s) {
    return s === "" || (/^(https:\/\/[^\s"'<>()\\]+|img\/negocios\/[A-Za-z0-9._\/-]+)$/.test(s) && s.length <= 300);
  }
  function iconoValido(s) { return s.length <= 8 && !/[<>&"'`]/.test(s); }

  // Solo viaja lo que el negocio definió; lo demás queda como el original.
  function leerTema() {
    var t = {};
    COLORES.forEach(function (k) { if (colorDis[k]) t[k] = colorDis[k]; });
    if ($("dis-fuente-titulo").value) t.fuente_titulo = $("dis-fuente-titulo").value;
    if ($("dis-fuente-texto").value) t.fuente_texto = $("dis-fuente-texto").value;
    ICONOS.forEach(function (c) {
      var v = $(c.campo).value.trim();
      if (v) t[c.clave] = v;
    });
    var img = $("dis-fondo-img").value.trim();
    if (img) t.fondo_img = img;
    else if (fondoFoto) t.fondo_img = fondoFoto;
    return t;
  }

  function validarDiseno(t) {
    if (t.acento && !hexValido(t.acento)) return "El color principal no es válido.";
    if (t.acento2 && !hexValido(t.acento2)) return "El color secundario no es válido.";
    if (t.fondo && !hexValido(t.fondo)) return "El color de fondo no es válido.";
    for (var i = 0; i < ICONOS.length; i++) {
      var v = t[ICONOS[i].clave];
      if (v && !iconoValido(v)) return "Cada ícono debe tener hasta 8 caracteres y no usar < > & \" ' `.";
    }
    if (t.fondo_img && !imagenValida(t.fondo_img) && !(esFoto(t.fondo_img) && t.fondo_img.length <= 150000)) return "La imagen de fondo debe ser un enlace https://… (hasta 300 caracteres) o una ruta img/negocios/….";
    return "";
  }

  // Maqueta del menú de caja y ejemplo de tarjeta (las fichas llevan el ícono de sellos)
  function actualizarMaqueta() {
    ICONOS.forEach(function (c) {
      if (c.maq) $(c.maq).textContent = $(c.campo).value.trim() || c.defecto;
    });
    var sello = $("dis-emoji-sello").value.trim() || "🦜";
    Array.prototype.forEach.call($("dis-sello-ej").querySelectorAll(".ej-emoji"), function (s) {
      s.textContent = sello;
    });
  }

  function vistaPrevia() {
    Q.tema(leerTema());
    actualizarMaqueta();
  }

  function pintarColores() {
    COLORES.forEach(function (k) {
      $(COLOR_ID[k]).value = colorDis[k] || ORIGINAL[k];
      $(COLOR_ID[k] + "-orig").disabled = !colorDis[k];
    });
  }

  function rellenarDiseno(t) {
    t = t || {};
    COLORES.forEach(function (k) { colorDis[k] = hexValido(t[k]) ? t[k].toLowerCase() : ""; });
    pintarColores();
    $("dis-fuente-titulo").value = t.fuente_titulo || "";
    $("dis-fuente-texto").value = t.fuente_texto || "";
    ICONOS.forEach(function (c) { $(c.campo).value = t[c.clave] || ""; });
    fondoFoto = esFoto(t.fondo_img) ? t.fondo_img : "";
    $("dis-fondo-img").value = fondoFoto ? "" : (t.fondo_img || "");
    pintarFondo();
    actualizarMaqueta();
  }

  // Campo de imagen y miniatura. La foto subida no aparece como texto: el campo queda vacío con «Foto subida».
  function pintarFondo() {
    var campo = $("dis-fondo-img");
    if (fondoFoto) campo.value = "";
    campo.placeholder = fondoFoto ? "Foto subida" : "https://…";
    var txt = campo.value.trim();
    var actual = fondoFoto || (imagenValida(txt) ? txt : "");
    var mini = $("dis-fondo-miniatura");
    mini.classList.toggle("oculto", !actual);
    if (actual) mini.src = Q.logo(actual);
    $("btn-quitar-fondo").disabled = !actual;
  }

  function alCambiarFondo() {
    if (this.value.trim()) fondoFoto = ""; // escribir un enlace reemplaza la foto
    pintarFondo();
    alCambiar();
  }

  // Usar la foto en el editor: queda en el formulario y en vista previa; se guarda con «Guardar diseño».
  function usarFondo() {
    var url = generarFondo();
    if (!url) return mensaje($("editor-msg"), "La foto pesa demasiado; prueba con otra", "error");
    fondoFoto = url;
    cerrarEditor();
    $("dis-fondo-img").value = "";
    pintarFondo();
    alCambiar();
    mensaje($("diseno-msg"), "Foto de fondo lista. Toca «Guardar diseño» para guardarla.", "aviso");
  }

  function alCambiar() {
    mensaje($("diseno-msg"), "", "");
    vistaPrevia();
  }

  function enviarDiseno(t, boton) {
    var err = validarDiseno(t);
    if (err) return mensaje($("diseno-msg"), err, "error");
    boton.disabled = true;
    mensaje($("diseno-msg"), "Guardando…", "aviso");
    Q.rpc("guardar_tema", { p_pin: pinActual, p_tema: t }).then(function (r) {
      boton.disabled = false;
      if (r.ok) {
        Q.tema(r.tema);
        rellenarDiseno(r.tema);
        return mensaje($("diseno-msg"), "Diseño guardado", "aviso");
      }
      if (r.error === "pin_invalido") return salirAlInicio();
      mensaje($("diseno-msg"), Q.msg(r.error), "error");
    });
  }

  // Estilos listos y sugerencias de íconos (botones creados aquí; sin innerHTML)
  var contEstilos = $("dis-estilos");
  ESTILOS.forEach(function (e) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "chip";
    var sw = document.createElement("span");
    sw.className = "chip-sw";
    sw.style.background = "linear-gradient(90deg, " + e[1] + " 33%, " + e[2] + " 33% 66%, " + e[3] + " 66%)";
    b.appendChild(sw);
    b.appendChild(document.createTextNode(e[0]));
    b.addEventListener("click", function () {
      colorDis.acento = e[1].toLowerCase();
      colorDis.acento2 = e[2].toLowerCase();
      colorDis.fondo = e[3].toLowerCase();
      pintarColores();
      alCambiar();
    });
    contEstilos.appendChild(b);
  });

  ICONOS.forEach(function (c) {
    var cont = $(c.sug);
    (c.sugs || SUGERENCIAS).forEach(function (em) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "sugerencia";
      b.textContent = em;
      b.addEventListener("click", function () {
        $(c.campo).value = em;
        alCambiar();
      });
      cont.appendChild(b);
    });
  });

  // Letras: opción «Original» (vacía) y las de Q.fuentes
  ["dis-fuente-titulo", "dis-fuente-texto"].forEach(function (id) {
    var sel = $(id);
    var o = document.createElement("option");
    o.value = "";
    o.textContent = "Original";
    sel.appendChild(o);
    Q.fuentes.forEach(function (f) {
      var op = document.createElement("option");
      op.value = f[0];
      op.textContent = f[1];
      sel.appendChild(op);
    });
    sel.addEventListener("change", alCambiar);
  });

  COLORES.forEach(function (k) {
    $(COLOR_ID[k]).addEventListener("input", function () {
      colorDis[k] = this.value;
      pintarColores();
      alCambiar();
    });
    $(COLOR_ID[k] + "-orig").addEventListener("click", function () {
      colorDis[k] = "";
      pintarColores();
      alCambiar();
    });
  });
  ICONOS.forEach(function (c) { $(c.campo).addEventListener("input", alCambiar); });
  $("dis-fondo-img").addEventListener("input", alCambiarFondo);
  $("btn-quitar-fondo").addEventListener("click", function () {
    fondoFoto = "";
    $("dis-fondo-img").value = "";
    pintarFondo();
    alCambiar();
  });

  // Guardar diseño: primero la apariencia del negocio (tipo, color de acento y logo, con guardar_config) y luego el tema visual.
  $("form-diseno").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var boton = $("btn-guardar-diseno");
    var d = leerForm();
    var err = "";
    if (d.tipo.length < 1 || d.tipo.length > 30) err = "El tipo de negocio debe tener de 1 a 30 caracteres.";
    else if (!logoValido(d.logo)) err = "El logo debe ser un enlace https://… (hasta 300 caracteres) o una ruta img/negocios/….";
    else if (d.color && !/^#[0-9a-fA-F]{6}$/.test(d.color)) err = "El color de acento no es válido.";
    if (err) return mensaje($("diseno-msg"), err, "error");
    boton.disabled = true;
    mensaje($("diseno-msg"), "Guardando…", "aviso");
    var args = { p_pin: pinActual, p_tipo: d.tipo, p_color: d.color };
    // Con foto subida y el campo de enlace vacío, la foto se conserva: no se envía p_logo.
    if (!(d.logo === "" && esFoto(logoActual))) args.p_logo = d.logo;
    Q.rpc("guardar_config", args).then(function (r) {
      if (!r.ok) {
        boton.disabled = false;
        if (r.error === "pin_invalido") return salirAlInicio();
        return mensaje($("diseno-msg"), Q.msg(r.error), "error");
      }
      rellenarForm(r);
      pintarCabecera(r);
      enviarDiseno(leerTema(), boton);
    });
  });
  $("btn-restablecer").addEventListener("click", function () {
    if (!window.confirm("¿Quitar tu diseño y volver a los colores originales?")) return;
    enviarDiseno({}, this);
  });

  iniciar();
})();
