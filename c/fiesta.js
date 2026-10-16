/*
 * Fiesta: animaciones de la tarjeta de lealtad (premio listo y recarga).
 * Expone window.Fiesta = { precargar, premioListo, recargar }. JS ES5, sin dependencias.
 * Estilos en c/fiesta.css; si la página no lo enlaza, este script lo añade junto a sí mismo.
 */
(function (w) {
  "use strict";

  var doc = w.document;
  var SPRITE = "../img/quetzalcoatl-vuelo.png";
  var COLORES = ["#D8A245", "#2E9F78", "#E26F57", "#F8ECD2"];
  var sprite = null;
  var enCurso = null; // { promesa } mientras corre recargar()

  // Enlaza fiesta.css si la página no lo tiene (mismo nombre que este archivo).
  (function cargarCss() {
    var scripts = doc.getElementsByTagName("script");
    var yo = doc.currentScript || scripts[scripts.length - 1];
    var src = yo && yo.getAttribute("src");
    if (!src) return;
    var href = src.replace(/\.js(\?.*)?$/, ".css");
    var enlaces = doc.getElementsByTagName("link");
    for (var i = 0; i < enlaces.length; i++) {
      if (enlaces[i].getAttribute("href") === href) return;
    }
    var link = doc.createElement("link");
    link.rel = "stylesheet";
    link.href = href;
    doc.head.appendChild(link);
  })();

  function rnd(a, b) { return a + Math.random() * (b - a); }

  function ahora() {
    return (w.performance && w.performance.now) ? w.performance.now() : Date.now();
  }

  function reducido() {
    return !!(w.matchMedia && w.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function nodo(tag, clase, estilo) {
    var el = doc.createElement(tag);
    el.className = clase;
    if (estilo) {
      for (var k in estilo) {
        if (Object.prototype.hasOwnProperty.call(estilo, k)) el.style.setProperty(k, estilo[k]);
      }
    }
    return el;
  }

  function quitar(el) {
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function seguro(fn, arg) {
    if (typeof fn !== "function") return;
    try { fn(arg); } catch (e) { if (w.console) w.console.error(e); }
  }

  // Centro de la zona en coordenadas de viewport (position: fixed).
  function centroDe(zona) {
    if (zona && zona.getBoundingClientRect) {
      var r = zona.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    }
    return { x: w.innerWidth / 2, y: w.innerHeight / 2 };
  }

  // Capa a pantalla completa, sin clics (z-index 60 en CSS).
  function capa() {
    var c = nodo("div", "fiesta-capa");
    c.setAttribute("aria-hidden", "true");
    doc.body.appendChild(c);
    return c;
  }

  function precargar() {
    if (!sprite) {
      sprite = new Image();
      sprite.decoding = "async";
      sprite.src = SPRITE;
    }
    return sprite;
  }

  function premioListo(opts) {
    opts = opts || {};
    var colores = (opts.colores && opts.colores.length) ? opts.colores : COLORES;
    var lienzo = capa();

    if (reducido()) {
      lienzo.appendChild(nodo("div", "fiesta-destello-suave", { "animation-duration": "500ms" }));
      w.setTimeout(function () { quitar(lienzo); }, 500);
      return;
    }

    var c = centroDe(opts.zona);
    var pos = { left: c.x + "px", top: c.y + "px" };
    lienzo.appendChild(nodo("div", "fiesta-anillo", pos));
    lienzo.appendChild(nodo("div", "fiesta-destello-zona", pos));

    var n = 28 + Math.floor(Math.random() * 9); // 28–36 piezas
    for (var i = 0; i < n; i++) {
      var ang = (-90 + rnd(-60, 60)) * Math.PI / 180; // abanico hacia arriba
      var vel = rnd(150, 300);
      var pieza;
      if (opts.emoji) {
        pieza = nodo("span", "fiesta-pieza fiesta-brota fiesta-emoji");
        pieza.textContent = opts.emoji;
      } else {
        pieza = nodo("span", "fiesta-pieza fiesta-brota fiesta-hoja");
        pieza.style.setProperty("--c", colores[i % colores.length]);
      }
      pieza.style.setProperty("--x0", c.x + "px");
      pieza.style.setProperty("--y0", c.y + "px");
      pieza.style.setProperty("--dx", (Math.cos(ang) * vel).toFixed(1) + "px");
      pieza.style.setProperty("--dy", (Math.sin(ang) * vel).toFixed(1) + "px");
      pieza.style.setProperty("--caida", rnd(160, 280).toFixed(1) + "px");
      pieza.style.setProperty("--rot", rnd(-540, 540).toFixed(0) + "deg");
      pieza.style.setProperty("animation-duration", rnd(1.3, 1.7).toFixed(2) + "s");
      pieza.style.setProperty("animation-delay", rnd(0, 0.1).toFixed(2) + "s");
      lienzo.appendChild(pieza);
    }

    w.setTimeout(function () { quitar(lienzo); }, 1800);
  }

  function recargar(opts) {
    if (enCurso) return enCurso.promesa; // ya hay una recarga: misma Promise, sin nodos duplicados
    opts = opts || {};

    var resolver;
    var promesa = new Promise(function (res) { resolver = res; });
    var estado = { promesa: promesa };
    enCurso = estado;

    var quetzal = !!opts.quetzalcoatl;
    var DUR = quetzal ? 2800 : 1700;
    var MEDIO = quetzal ? 0.5 : 0.45;
    var lienzo = capa();
    var enMedioHecho = false;
    var fin = false;
    var rafId = null;
    var timerId = null;

    function terminar() {
      if (fin) return;
      fin = true;
      if (rafId !== null) w.cancelAnimationFrame(rafId);
      if (timerId !== null) w.clearTimeout(timerId);
      quitar(lienzo);
      enCurso = null;
      seguro(opts.alTerminar);
      resolver();
    }

    // Movimiento reducido: sin sprite ni confeti, solo un fundido breve.
    if (reducido()) {
      enMedioHecho = true;
      seguro(opts.enMedio);
      lienzo.appendChild(nodo("div", "fiesta-destello-suave", { "animation-duration": "300ms" }));
      timerId = w.setTimeout(terminar, 300);
      return promesa;
    }

    var vw = w.innerWidth;
    var vh = w.innerHeight;
    var c = centroDe(opts.zona);
    var t0 = null;
    var pulso = function () {
      lienzo.appendChild(nodo("div", "fiesta-pulso", { left: (vw / 2) + "px", top: (vh / 2) + "px" }));
    };

    var mover = null;
    var lanzarEstela = null;

    if (quetzal) {
      precargar();
      var ancho = Math.min(vw * 0.88, 440);
      var alto = ancho * 478 / 720;
      var amp = vh * 0.08;
      var base = (vh - alto) / 2;
      var recorrido = vw + ancho;
      var ciclos = 1.5;
      var nEstela = 14 + Math.floor(Math.random() * 7); // 14–20
      var lanzadas = 0;

      var velo = nodo("div", "fiesta-velo", { "animation-duration": DUR + "ms" });
      var img = nodo("img", "fiesta-quetzal");
      img.src = SPRITE;
      img.alt = "";
      img.style.width = ancho.toFixed(1) + "px";
      lienzo.appendChild(velo);
      lienzo.appendChild(img);

      lanzarEstela = function (hx, hy) {
        var el = nodo("span", "fiesta-estela-pieza" + (Math.random() < 0.5 ? "" : " fiesta-pluma"));
        el.style.setProperty("--x0", (hx - rnd(0, 20)).toFixed(1) + "px");
        el.style.setProperty("--y0", (hy + rnd(-amp * 0.5, amp * 0.5)).toFixed(1) + "px");
        el.style.setProperty("--dx", rnd(30, 70).toFixed(1) + "px");
        el.style.setProperty("--dy", rnd(-20, 20).toFixed(1) + "px");
        el.style.setProperty("--rot", rnd(-200, 200).toFixed(0) + "deg");
        el.addEventListener("animationend", function () { quitar(el); });
        lienzo.appendChild(el);
      };

      mover = function (p) {
        var x = -ancho + p * recorrido;                 // entra por la izquierda, sale por la derecha
        var fase = 2 * Math.PI * ciclos * p;
        var y = base + amp * Math.sin(fase);            // onda de 1.5 ciclos
        var pendiente = amp * 2 * Math.PI * ciclos * Math.cos(fase) / recorrido;
        var giro = Math.max(-14, Math.min(14, Math.atan(pendiente) * 180 / Math.PI));
        img.style.transform = "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) rotate(" + giro.toFixed(2) + "deg)";
        while (lanzadas < nEstela && p >= 0.06 + lanzadas * (0.86 / nEstela)) {
          lanzarEstela(x + ancho * 0.9, y + alto * 0.4);
          lanzadas++;
        }
      };
    } else {
      // Negocio: barrido diagonal de luz y piezas que suben y se desvanecen.
      lienzo.appendChild(nodo("div", "fiesta-barrido", { "animation-duration": DUR + "ms" }));
      var n = 18 + Math.floor(Math.random() * 7); // 18–24
      for (var i = 0; i < n; i++) {
        var pieza;
        if (opts.emoji) {
          pieza = nodo("span", "fiesta-pieza fiesta-sube fiesta-emoji");
          pieza.textContent = opts.emoji;
        } else {
          pieza = nodo("span", "fiesta-pieza fiesta-sube fiesta-estrella");
        }
        pieza.style.setProperty("--x0", (c.x + rnd(-0.35, 0.35) * vw).toFixed(1) + "px");
        pieza.style.setProperty("--y0", (c.y + rnd(-30, 30)).toFixed(1) + "px");
        pieza.style.setProperty("--dx", rnd(-60, 60).toFixed(1) + "px");
        pieza.style.setProperty("--subida", rnd(120, 260).toFixed(1) + "px");
        pieza.style.setProperty("animation-duration", rnd(1.1, 1.4).toFixed(2) + "s");
        pieza.style.setProperty("animation-delay", rnd(0, 0.2).toFixed(2) + "s");
        lienzo.appendChild(pieza);
      }
    }

    function tick() {
      rafId = null;
      if (fin) return;
      var ahoraMs = ahora();
      if (t0 === null) t0 = ahoraMs;
      var p = Math.min(1, (ahoraMs - t0) / DUR); // con marcas de tiempo: al volver de segundo plano termina sin acumular frames

      if (!enMedioHecho && p >= MEDIO) {
        enMedioHecho = true;
        if (quetzal) pulso();
        seguro(opts.enMedio);
      }
      if (mover) mover(p);
      if (p >= 1) { terminar(); return; }
      rafId = w.requestAnimationFrame(tick);
    }

    rafId = w.requestAnimationFrame(tick);
    return promesa;
  }

  w.Fiesta = {
    precargar: precargar,
    premioListo: premioListo,
    recargar: recargar
  };

})(window);

/*
 * Prueba desde la consola (sin c.js). Descomenta o pega en la consola de la página:
 *
 * Fiesta.precargar();
 * Fiesta.premioListo({ zona: document.querySelector(".sellos") || document.body, emoji: null });
 * Fiesta.recargar({
 *   zona: document.body,
 *   quetzalcoatl: true,
 *   emoji: null,
 *   enMedio: function () { console.log("enMedio"); },
 *   alTerminar: function () { console.log("alTerminar"); }
 * }).then(function () { console.log("resuelta"); });
 */
