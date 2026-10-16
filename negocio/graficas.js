/*
 * Graficas: gráficas SVG sobrias para las métricas del panel del negocio.
 * ES5, sin dependencias. Estilos en graficas.css (clases gr-*, colores por variables CSS).
 * Todas pintan dentro de `el` (vacían antes con replaceChildren) y usan solo textContent.
 * Ejemplos de llamada al final del archivo.
 */
(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var DIAS = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  var DIAS_LARGO = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
  var MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  var SERIE_NOMBRE = { ventas: ['venta', 'ventas'], registros: ['registro', 'registros'], canjes: ['canje', 'canjes'] };
  var uid = 0;

  /* ---------- utilidades ---------- */

  function num(v) {
    v = Number(v);
    return isFinite(v) && v > 0 ? v : 0;
  }

  function clamp(v, a, b) {
    return Math.max(a, Math.min(b, v));
  }

  function pct(parte, total) {
    return total > 0 ? Math.min(100, Math.round(parte / total * 100)) : 0;
  }

  function capital(s) {
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function nombreSerie(clave, n) {
    var p = SERIE_NOMBRE[clave] || ['valor', 'valores'];
    return n === 1 ? p[0] : p[1];
  }

  function fecha(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(s));
    return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
  }

  function fechaCorta(d) {
    return d.getDate() + ' ' + MESES[d.getMonth()];
  }

  function fechaLarga(d) {
    return fechaCorta(d) + ' ' + d.getFullYear();
  }

  function niceMax(m) {
    if (m <= 0) return 1;
    var e = Math.pow(10, Math.floor(Math.log(m) / Math.LN10));
    var f = m / e;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e;
  }

  function svgEl(tag, attrs, padre) {
    var n = document.createElementNS(NS, tag);
    if (attrs) {
      for (var k in attrs) {
        if (attrs.hasOwnProperty(k) && attrs[k] != null) n.setAttribute(k, attrs[k]);
      }
    }
    if (padre) padre.appendChild(n);
    return n;
  }

  function svgTexto(padre, x, y, texto, attrs) {
    var t = svgEl('text', attrs || {}, padre);
    t.setAttribute('x', x);
    t.setAttribute('y', y);
    t.textContent = texto;
    return t;
  }

  function elHtml(tag, clase, texto, padre) {
    var n = document.createElement(tag);
    if (clase) n.className = clase;
    if (texto != null) n.textContent = texto;
    if (padre) padre.appendChild(n);
    return n;
  }

  /* Vacía el contenedor y lo prepara (idempotente). */
  function preparar(el) {
    el.replaceChildren();
    el.classList.add('gr-caja');
    return el;
  }

  function vacio(el) {
    preparar(el);
    var d = elHtml('div', 'gr-vacio', null, el);
    d.setAttribute('role', 'img');
    d.setAttribute('aria-label', 'Aún no hay datos en este periodo');
    elHtml('span', 'gr-rombo', null, d).setAttribute('aria-hidden', 'true');
    elHtml('span', null, 'Aún no hay datos en este periodo', d);
  }

  function crearSvg(W, H, etiqueta, padre) {
    var svg = svgEl('svg', {
      'class': 'gr-svg',
      viewBox: '0 0 ' + W + ' ' + H,
      role: 'img',
      'aria-label': etiqueta,
      focusable: 'false'
    }, padre);
    return svg;
  }

  /* Degradado lineal con stops [offset, color, opacidad]; devuelve la referencia url(#id). */
  function degradado(svg, id, stops, x1, y1, x2, y2) {
    var defs = svgEl('defs', null, svg);
    var g = svgEl('linearGradient', { id: id, x1: x1, y1: y1, x2: x2, y2: y2 }, defs);
    stops.forEach(function (s) {
      var st = svgEl('stop', { offset: s[0] }, g);
      st.setAttribute('style', 'stop-color:' + s[1] + ';stop-opacity:' + s[2]);
    });
    return 'url(#' + id + ')';
  }

  /* Zona de impacto enfocable (tabindex) con <title> para lectores de pantalla. */
  function zona(svg, x, y, w, h, txt) {
    var g = svgEl('g', { 'class': 'gr-barra-zona', tabindex: '0', role: 'img', 'aria-label': txt }, svg);
    svgEl('title', null, g).textContent = txt;
    svgEl('rect', { 'class': 'gr-zona', x: x, y: y, width: w, height: h }, g);
    return g;
  }

  /* ---------- tooltip compartido por contenedor ---------- */

  function crearTip(el) {
    return elHtml('div', 'gr-tip', null, el);
  }

  function setTip(tip, lineas) {
    tip.replaceChildren();
    for (var i = 0; i < lineas.length; i++) elHtml('span', null, lineas[i], tip);
  }

  /* r: rectángulo (viewport) del ancla. Centra sobre ella y se limita a los bordes de el. */
  function mostrarTip(el, tip, r, lineas) {
    setTip(tip, lineas);
    tip.classList.add('on');
    var er = el.getBoundingClientRect();
    var w = tip.offsetWidth, h = tip.offsetHeight;
    var cx = r.left + r.width / 2 - er.left;
    var left = clamp(cx - w / 2, 4, Math.max(4, el.clientWidth - w - 4));
    var top = r.top - er.top - h - 8;
    if (top < 0) top = r.bottom - er.top + 8;
    tip.style.left = left + 'px';
    tip.style.top = top + 'px';
  }

  function ocultarTip(tip) {
    tip.classList.remove('on');
  }

  function enlazarTip(g, ancla, el, tip, lineas) {
    function on() { mostrarTip(el, tip, ancla.getBoundingClientRect(), lineas); }
    function off() { ocultarTip(tip); }
    g.addEventListener('focus', on);
    g.addEventListener('blur', off);
    g.addEventListener('pointerenter', on);
    g.addEventListener('pointerleave', off);
  }

  /* ---------- API ---------- */

  /* Relanza las animaciones de entrada (p. ej. al abrir un <details>). */
  function animar(el) {
    if (!el) return;
    el.classList.remove('grafica-anima');
    void el.offsetWidth; // fuerza reflujo para reiniciar la animación
    el.classList.add('grafica-anima');
  }

  function fmt12(h) {
    if (h === 0) return '12a';
    if (h < 12) return h + 'a';
    return h === 12 ? '12p' : (h - 12) + 'p';
  }

  /* «1–2 pm», «11 am–12 pm» */
  function rango(h) {
    var h2 = (h + 1) % 24;
    var n = function (x) { return (x % 12) || 12; };
    var s = function (x) { return x < 12 ? 'am' : 'pm'; };
    var a = n(h) + (s(h) !== s(h2) ? ' ' + s(h) : '');
    return a + '–' + n(h2) + ' ' + s(h2);
  }

  /* porHora: [{h:0..23, ventas, registros, canjes}]; clave: "ventas" | "registros" | "canjes" */
  function horas(el, porHora, clave) {
    if (!el) return null;
    var k = SERIE_NOMBRE[clave] ? clave : 'ventas';
    var vals = [], i, total = 0, max = 0, pico = -1;
    for (i = 0; i < 24; i++) vals.push(0);
    (porHora || []).forEach(function (o) {
      var h = Math.floor(Number(o && o.h));
      if (h >= 0 && h < 24) vals[h] += num(o[k]);
    });
    for (i = 0; i < 24; i++) {
      total += vals[i];
      if (vals[i] > max) { max = vals[i]; pico = i; }
    }
    if (total === 0) { vacio(el); return { pico: null, total: 0, textoPico: null }; }

    preparar(el);
    var W = 360, H = 196, x0 = 8, x1 = 352, y0 = 26, y1 = 166;
    var slot = (x1 - x0) / 24, bw = slot * 0.62;
    var svg = crearSvg(W, H, capital(k) + ' por hora. Hora pico ' + rango(pico) + ' con ' + max + ' ' +
      nombreSerie(k, max) + '. Total ' + total + '.', el);
    var grad = degradado(svg, 'gr-h' + (++uid), [[0, 'var(--esmeralda)', 1], [1, 'var(--naranja)', 1]], 0, 1, 0, 0);
    var tip = crearTip(el);
    svgEl('line', { 'class': 'gr-eje', x1: x0, x2: x1, y1: y1, y2: y1 }, svg);

    for (i = 0; i < 24; i++) {
      var v = vals[i];
      var hh = max > 0 ? v / max * (y1 - y0) : 0;
      var cx = x0 + i * slot + slot / 2, bx = cx - bw / 2;
      var txt = rango(i) + ': ' + v + ' ' + nombreSerie(k, v);
      var g = zona(svg, x0 + i * slot, 4, slot, y1, txt);
      var ancla = g;
      if (hh > 0) {
        var r = Math.min(4, bw / 2, hh);
        var d = 'M' + bx + ',' + y1 + ' L' + bx + ',' + (y1 - hh + r) +
          ' Q' + bx + ',' + (y1 - hh) + ' ' + (bx + r) + ',' + (y1 - hh) +
          ' L' + (bx + bw - r) + ',' + (y1 - hh) +
          ' Q' + (bx + bw) + ',' + (y1 - hh) + ' ' + (bx + bw) + ',' + (y1 - hh + r) +
          ' L' + (bx + bw) + ',' + y1 + ' Z';
        var p = svgEl('path', {
          'class': 'gr-barra ' + (i === pico ? 'gr-barra--pico' : 'gr-barra--tenue'),
          d: d,
          fill: grad
        }, g);
        p.style.setProperty('--retraso', (i * 18) + 'ms');
        ancla = p;
      }
      enlazarTip(g, ancla, el, tip, [txt]);
    }

    svgTexto(svg, x0 + pico * slot + slot / 2, y0 - 8, String(max), { 'class': 'gr-valor', 'text-anchor': 'middle' });
    for (i = 0; i < 24; i += 3) {
      svgTexto(svg, x0 + i * slot + slot / 2, H - 6, fmt12(i), { 'class': 'gr-eje-txt', 'text-anchor': 'middle' });
    }

    if (el.offsetParent !== null) el.classList.add('grafica-anima');
    return { pico: { h: pico, valor: max }, total: total, textoPico: rango(pico) };
  }

  /* porDia: [{d:1..7 (1=lunes), ventas, reclamos}] */
  function semana(el, porDia) {
    if (!el) return null;
    var v = [0, 0, 0, 0, 0, 0, 0], r = [0, 0, 0, 0, 0, 0, 0];
    var i, tv = 0, tr = 0, max = 0, mejor = -1;
    (porDia || []).forEach(function (o) {
      var d = Math.floor(Number(o && o.d));
      if (d >= 1 && d <= 7) { v[d - 1] += num(o.ventas); r[d - 1] += num(o.reclamos); }
    });
    for (i = 0; i < 7; i++) {
      tv += v[i];
      tr += r[i];
      if (v[i] > max) { max = v[i]; mejor = i; }
    }
    if (tv + tr === 0) { vacio(el); return { mejor: null, total: 0 }; }

    preparar(el);
    var W = 320, RH = 40, TOP = 4, BX = 46, ML = 168, H = TOP + 7 * RH + 4;
    var svg = crearSvg(W, H, 'Ventas por día de la semana. ' +
      (mejor >= 0 ? 'Mejor día ' + DIAS_LARGO[mejor] + ' con ' + max + ' ventas. ' : '') + 'Total ' + tv + '.', el);
    var grad = degradado(svg, 'gr-s' + (++uid), [[0, 'var(--esmeralda)', 1], [1, 'var(--naranja)', 1]], 0, 0, 1, 0);
    var tip = crearTip(el);

    for (i = 0; i < 7; i++) {
      var y = TOP + i * RH, cy = y + RH / 2;
      var len = max > 0 ? v[i] / max * ML : 0;
      var txt = capital(DIAS_LARGO[i]) + ': ' + v[i] + ' ' + nombreSerie('ventas', v[i]) + ', ' +
        r[i] + ' ' + (r[i] === 1 ? 'reclamo' : 'reclamos');
      var g = zona(svg, 0, y, W, RH, txt);
      svgTexto(g, 0, cy + 4, DIAS[i], { 'class': 'gr-etiqueta' });
      svgEl('rect', { 'class': 'gr-track', x: BX, y: cy - 8, width: ML, height: 16, rx: 8 }, g);
      var attrs = { 'class': 'gr-barra-h', x: BX, y: cy - 8, width: len, height: 16, rx: 8 };
      if (i === mejor) attrs.fill = grad; else attrs['class'] += ' gr-h-tenue';
      var barra = null;
      if (len > 0) {
        barra = svgEl('rect', attrs, g);
        barra.style.setProperty('--retraso', (i * 18) + 'ms');
      }
      svgTexto(g, BX + len + 8, cy + 4, String(v[i]), { 'class': 'gr-valor-h' });
      if (i === mejor) {
        svgEl('rect', { 'class': 'gr-badge', x: W - 70, y: cy - 10, width: 70, height: 20, rx: 10 }, g);
        svgTexto(g, W - 35, cy + 4, 'Mejor día', { 'class': 'gr-badge-txt', 'text-anchor': 'middle' });
      }
      enlazarTip(g, barra || g, el, tip, [txt]);
    }

    if (el.offsetParent !== null) el.classList.add('grafica-anima');
    return {
      mejor: mejor >= 0 ? { d: mejor + 1, valor: max, nombre: capital(DIAS_LARGO[mejor]) } : null,
      total: tv
    };
  }

  /* Agrupa puntos ordenados por semana (lunes). */
  function agrupar(ps) {
    var grupos = [], mapa = {};
    ps.forEach(function (p) {
      var lunes = new Date(p.d.getFullYear(), p.d.getMonth(), p.d.getDate() - ((p.d.getDay() + 6) % 7));
      var k = lunes.getTime();
      if (!mapa.hasOwnProperty(k)) {
        mapa[k] = { d: lunes, ventas: 0, reclamos: 0 };
        grupos.push(mapa[k]);
      }
      mapa[k].ventas += p.ventas;
      mapa[k].reclamos += p.reclamos;
    });
    return grupos;
  }

  /* Trazo suave (Catmull-Rom convertido a Bézier), con controles acotados al área. */
  function curva(xs, ys, top, bottom) {
    var d = 'M' + xs[0] + ',' + ys[0];
    for (var i = 0; i < xs.length - 1; i++) {
      var i0 = Math.max(0, i - 1), i3 = Math.min(xs.length - 1, i + 2);
      var c1x = xs[i] + (xs[i + 1] - xs[i0]) / 6;
      var c1y = clamp(ys[i] + (ys[i + 1] - ys[i0]) / 6, top, bottom);
      var c2x = xs[i + 1] - (xs[i3] - xs[i]) / 6;
      var c2y = clamp(ys[i + 1] - (ys[i3] - ys[i]) / 6, top, bottom);
      d += ' C' + c1x + ',' + c1y + ' ' + c2x + ',' + c2y + ' ' + xs[i + 1] + ',' + ys[i + 1];
    }
    return d;
  }

  /* puntos: [{dia:'AAAA-MM-DD', ventas, reclamos}] */
  function serie(el, puntos) {
    if (!el) return null;
    var ps = [], tv = 0, tr = 0;
    (puntos || []).forEach(function (p) {
      var d = fecha(p && p.dia);
      if (d) ps.push({ d: d, ventas: num(p.ventas), reclamos: num(p.reclamos) });
    });
    ps.sort(function (a, b) { return a.d - b.d; });
    ps.forEach(function (p) { tv += p.ventas; tr += p.reclamos; });
    if (!ps.length || tv + tr === 0) { vacio(el); return { total_ventas: tv, total_reclamos: tr }; }

    var agrupa = ps.length > 120;
    var pts = agrupa ? agrupar(ps) : ps;
    var n = pts.length;
    var W = 360, H = 184, x0 = 40, x1 = 352, y0 = 12, y1 = 146;
    var m = 0;
    pts.forEach(function (p) { m = Math.max(m, p.ventas, p.reclamos); });
    var mx = niceMax(m);
    function X(i) { return n === 1 ? (x0 + x1) / 2 : x0 + i * (x1 - x0) / (n - 1); }
    function Y(v) { return y1 - v / mx * (y1 - y0); }

    preparar(el);
    var svg = crearSvg(W, H, 'Ventas y reclamos ' + (agrupa ? 'por semana' : 'por día') + '. Total de ventas ' +
      tv + ', reclamos ' + tr + '.', el);
    var idV = 'gr-av' + (++uid), idR = 'gr-ar' + (++uid);
    var gV = degradado(svg, idV, [[0, 'var(--naranja)', 0.38], [1, 'var(--naranja)', 0]], 0, 0, 0, 1);
    var gR = degradado(svg, idR, [[0, 'var(--esmeralda)', 0.34], [1, 'var(--esmeralda)', 0]], 0, 0, 0, 1);

    [0, mx / 2, mx].forEach(function (v, k) {
      var yy = Y(v);
      if (k > 0) svgEl('line', { 'class': 'gr-rejilla', x1: x0, x2: x1, y1: yy, y2: yy }, svg);
      svgTexto(svg, x0 - 8, yy + 4, String(Math.round(v)), { 'class': 'gr-eje-txt', 'text-anchor': 'end' });
    });
    svgEl('line', { 'class': 'gr-eje', x1: x0, x2: x1, y1: y1, y2: y1 }, svg);

    var xs = [], yV = [], yR = [];
    pts.forEach(function (p, i) { xs.push(X(i)); yV.push(Y(p.ventas)); yR.push(Y(p.reclamos)); });

    if (n === 1) {
      svgEl('circle', { 'class': 'gr-punto-unico-oro', cx: xs[0], cy: yV[0], r: 4 }, svg);
      svgEl('circle', { 'class': 'gr-punto-unico-jade', cx: xs[0], cy: yR[0], r: 4 }, svg);
    } else {
      var aV = curva(xs, yV, y0, y1) + ' L' + xs[n - 1] + ',' + y1 + ' L' + xs[0] + ',' + y1 + ' Z';
      var aR = curva(xs, yR, y0, y1) + ' L' + xs[n - 1] + ',' + y1 + ' L' + xs[0] + ',' + y1 + ' Z';
      svgEl('path', { 'class': 'gr-area', d: aR, fill: gR }, svg);
      svgEl('path', { 'class': 'gr-area', d: aV, fill: gV }, svg);
      svgEl('path', { 'class': 'gr-linea gr-linea-jade', d: curva(xs, yR, y0, y1) }, svg);
      svgEl('path', { 'class': 'gr-linea gr-linea-oro', d: curva(xs, yV, y0, y1) }, svg);
    }

    /* Ejes X: 3 a 4 fechas, sin traslapes */
    var k = n >= 4 ? 4 : n, usados = {};
    for (var j = 0; j < k; j++) {
      var idx = k === 1 ? 0 : Math.round(j * (n - 1) / (k - 1));
      if (usados[idx]) continue;
      usados[idx] = true;
      var anc = n === 1 ? 'middle' : (j === 0 ? 'start' : (j === k - 1 ? 'end' : 'middle'));
      svgTexto(svg, X(idx), H - 8, fechaCorta(pts[idx].d), { 'class': 'gr-eje-txt', 'text-anchor': anc });
    }

    /* Guía y tooltip al tocar o arrastrar */
    var hg = svgEl('g', { 'class': 'gr-hover' }, svg);
    svgEl('line', { 'class': 'gr-guia', x1: 0, x2: 0, y1: y0, y2: y1 }, hg);
    svgEl('circle', { 'class': 'gr-hover-oro', cx: 0, cy: 0, r: 4.5 }, hg);
    svgEl('circle', { 'class': 'gr-hover-jade', cx: 0, cy: 0, r: 4.5 }, hg);
    var guia = hg.firstChild;
    var cO = hg.childNodes[1], cJ = hg.childNodes[2];
    var tip = crearTip(el);

    function marcar(ev) {
      var rr = svg.getBoundingClientRect();
      var xs2 = (ev.clientX - rr.left) * W / rr.width;
      var i = n === 1 ? 0 : clamp(Math.round((xs2 - x0) / ((x1 - x0) / (n - 1))), 0, n - 1);
      var p = pts[i];
      guia.setAttribute('x1', X(i)); guia.setAttribute('x2', X(i));
      cO.setAttribute('cx', X(i)); cO.setAttribute('cy', yV[i]);
      cJ.setAttribute('cx', X(i)); cJ.setAttribute('cy', yR[i]);
      hg.classList.add('on');
      var px = rr.left + X(i) * rr.width / W;
      var ty = rr.top + y0 * rr.height / H;
      mostrarTip(el, tip, { left: px, right: px, width: 0, top: ty, bottom: ty + 1 }, [
        agrupa ? 'Semana del ' + fechaCorta(p.d) : fechaLarga(p.d),
        'Ventas: ' + p.ventas,
        'Reclamos: ' + p.reclamos
      ]);
    }
    function ocultar() {
      hg.classList.remove('on');
      ocultarTip(tip);
    }
    var activo = false;
    svg.addEventListener('pointerdown', function (ev) { activo = true; marcar(ev); });
    svg.addEventListener('pointermove', function (ev) {
      if (activo || ev.pointerType === 'mouse') marcar(ev);
    });
    svg.addEventListener('pointerup', function (ev) {
      activo = false;
      if (ev.pointerType === 'touch') ocultar();
    });
    svg.addEventListener('pointercancel', function () { activo = false; ocultar(); });
    svg.addEventListener('pointerleave', function () { activo = false; ocultar(); });

    var leyenda = elHtml('div', 'gr-leyenda', null, el);
    var l1 = elHtml('span', null, null, leyenda);
    elHtml('i', 'gr-punto', null, l1);
    elHtml('span', null, 'Ventas', l1);
    var l2 = elHtml('span', null, null, leyenda);
    elHtml('i', 'gr-punto gr-punto--jade', null, l2);
    elHtml('span', null, 'Reclamos', l2);
    if (agrupa) elHtml('span', null, '· por semana', leyenda);

    return { total_ventas: tv, total_reclamos: tr };
  }

  /* datos: {clientes, nuevos, antiguos, repiten} */
  function mezcla(el, datos) {
    if (!el) return null;
    var d = datos || {};
    var clientes = num(d.clientes), nuevos = num(d.nuevos), antiguos = num(d.antiguos), repiten = num(d.repiten);
    var base = (nuevos + antiguos) || clientes;
    if (base === 0) { vacio(el); return { pct_nuevos: 0, pct_repiten: 0 }; }

    var pN = pct(nuevos, base), pA = pct(antiguos, base);
    var pR = pct(repiten, clientes || base);
    preparar(el);
    var W = 320;
    var svg = crearSvg(W, 28, pN + ' % clientes nuevos y ' + pA + ' % que ya eran clientes.', el);
    svgEl('rect', { 'class': 'gr-seg-jade', x: 0, y: 0, width: W, height: 28, rx: 14 }, svg);
    var wN = clamp(W * nuevos / base, 0, W);
    if (wN > 0) svgEl('rect', { 'class': 'gr-seg-oro', x: 0, y: 0, width: wN, height: 28, rx: 14 }, svg);

    var cif = elHtml('div', 'gr-mezcla-cifras', null, el);
    var c1 = elHtml('div', null, null, cif);
    elHtml('i', 'gr-punto', null, c1);
    elHtml('strong', null, 'Nuevos', c1);
    elHtml('span', null, pN + ' % · ' + nuevos, c1);
    var c2 = elHtml('div', null, null, cif);
    elHtml('i', 'gr-punto gr-punto--jade', null, c2);
    elHtml('strong', null, 'Ya eran clientes', c2);
    elHtml('span', null, pA + ' % · ' + antiguos, c2);

    var med = elHtml('div', 'gr-medidor', null, el);
    elHtml('p', 'gr-medidor-titulo', 'Repitieron en el periodo', med);
    var grande = elHtml('div', 'gr-grande', String(repiten), med);
    elHtml('small', null, pR + ' %', grande);
    var sm = svgEl('svg', { 'class': 'gr-svg gr-medidor-barra', viewBox: '0 0 ' + W + ' 10', role: 'img',
      'aria-label': 'Repitieron el ' + pR + ' % de los clientes' }, med);
    svgEl('rect', { 'class': 'gr-track', x: 0, y: 0, width: W, height: 10, rx: 5 }, sm);
    if (pR > 0) svgEl('rect', { 'class': 'gr-seg-oro', x: 0, y: 0, width: W * pR / 100, height: 10, rx: 5 }, sm);

    return { pct_nuevos: pN, pct_repiten: pR };
  }

  /* datos: {ventas (QR generados), reclamos (QR escaneados), canjes (premios canjeados)} */
  function embudo(el, datos) {
    if (!el) return null;
    var d = datos || {};
    var v = num(d.ventas), r = num(d.reclamos), c = num(d.canjes);
    var base = Math.max(v, r, c);
    if (base === 0) { vacio(el); return { adopcion: 0, canje: 0 }; }

    var adop = pct(r, v), canje = pct(c, r);
    var filas = [
      { t: 'QR generados', n: v, cls: 'gr-emb-1' },
      { t: 'QR escaneados', n: r, cls: 'gr-emb-2' },
      { t: 'Premios canjeados', n: c, cls: 'gr-emb-3' }
    ];
    var conv = ['Adopción ' + adop + ' %', 'Canje ' + canje + ' %'];
    var W = 320, FH = 46, GAP = 36, H = 4 + 3 * FH + 2 * GAP + 4;

    preparar(el);
    var svg = crearSvg(W, H, 'Embudo: ' + filas[0].n + ' QR generados, ' + filas[1].n + ' escaneados, ' +
      filas[2].n + ' premios canjeados. ' + conv[0] + '. ' + conv[1] + '.', el);

    filas.forEach(function (f, i) {
      var top = 4 + i * (FH + GAP);
      svgTexto(svg, 0, top + 12, f.t, { 'class': 'gr-etiqueta' });
      svgTexto(svg, W, top + 12, String(f.n), { 'class': 'gr-valor', 'text-anchor': 'end' });
      svgEl('rect', { 'class': 'gr-track', x: 0, y: top + 20, width: W, height: 22, rx: 11 }, svg);
      var w = clamp(W * f.n / base, 0, W);
      if (w > 0) svgEl('rect', { 'class': 'gr-emb ' + f.cls, x: 0, y: top + 20, width: w, height: 22, rx: 11 }, svg);
      if (i < 2) {
        var cy = top + FH + GAP / 2;
        svgEl('path', { 'class': 'gr-chev', d: 'M6,' + (cy - 3) + ' L12,' + (cy + 3) + ' L18,' + (cy - 3) }, svg);
        svgTexto(svg, 28, cy + 4, conv[i], { 'class': 'gr-conv' });
      }
    });

    return { adopcion: adop, canje: canje };
  }

  window.Graficas = {
    horas: horas,
    semana: semana,
    serie: serie,
    mezcla: mezcla,
    embudo: embudo,
    animar: animar
  };
})();

/*
 * Ejemplos para probar en la consola (sobre un <div> con ancho de 320-360 px dentro de la página):
 *
 * var el = document.createElement('div');
 * document.body.appendChild(el);
 * Graficas.horas(el, [{h: 13, ventas: 18, registros: 3, canjes: 1}, {h: 9, ventas: 6, registros: 2, canjes: 0}], 'ventas');
 * Graficas.semana(el, [{d: 1, ventas: 12, reclamos: 1}, {d: 6, ventas: 30, reclamos: 4}]);
 * Graficas.serie(el, [{dia: '2026-10-12', ventas: 20, reclamos: 3}, {dia: '2026-10-13', ventas: 14, reclamos: 1}]);
 * Graficas.mezcla(el, {clientes: 50, nuevos: 20, antiguos: 30, repiten: 18});
 * Graficas.embudo(el, {ventas: 120, reclamos: 90, canjes: 11});
 * Graficas.animar(el);
 */
