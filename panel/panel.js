(function () {
  'use strict';

  // La clave admin vive solo aquí, en memoria: nunca en storage, URL ni consola.
  let clave = null;
  let dias = 7;
  let pedido = 0; // descarta respuestas viejas si el periodo cambia mientras carga

  const $ = (id) => document.getElementById(id);
  const form = $('form-clave');
  const inputClave = $('clave');
  const selPeriodo = $('periodo');
  const boton = $('ver');
  const estado = $('estado');
  const errorEl = $('error');
  const tabla = $('tabla');
  const cuerpo = $('cuerpo');
  const seccionNueva = $('nueva');
  const formNueva = $('form-nueva');
  const inNombre = $('n-nombre');
  const inEscuela = $('n-escuela');
  const inPin = $('n-pin');
  const btnCrear = $('n-crear');
  const okNueva = $('n-ok');
  const errorNueva = $('n-error');
  const slugNueva = $('n-slug-res');
  const listaEscuelas = $('escuelas');
  const formEliminar = $('form-eliminar');
  const selCual = $('e-cual');
  const btnBorrar = $('e-borrar');
  const cajaConfirmar = $('e-confirmar');
  const preguntaEl = $('e-pregunta');
  const btnSi = $('e-si');
  const btnNo = $('e-no');
  const okElim = $('e-ok');
  const errorElim = $('e-error');
  let pendiente = null; // baja que espera confirmación: { slug, texto }
  let ultimaAlta = null; // slug de la última cafetería creada: su aviso lleva el PIN
  let ultimaEdicionPin = null; // slug de la última cafetería con PIN cambiado: su aviso lleva el PIN
  const seccionEditar = $('editar');
  const formEditar = $('form-editar');
  const selMCual = $('m-cual');
  const inMNombre = $('m-nombre');
  const inMEscuela = $('m-escuela');
  const inMPin = $('m-pin');
  const inMActiva = $('m-activa');
  const inMDistribuidor = $('m-distribuidor');
  const inMTope = $('m-tope');
  const btnGuardar = $('m-guardar');
  const okEditar = $('m-ok');
  const errorEditar = $('m-error');
  let filasActuales = []; // últimas filas de métricas: alimentan la sección de edición
  let rellenarTrasGuardar = false; // el siguiente refresco vuelve a llenar el formulario de edición con datos del servidor

  // Tarjeta Quetzalitos: la meta, la palabra, el premio y el mensaje que ve el cliente.
  const seccionQ = $('quetzalitos');
  const formQ = $('form-quetzalitos');
  const inQMeta = $('q-meta');
  const inQUnidad = $('q-unidad');
  const inQPremio = $('q-premio');
  const inQMensaje = $('q-mensaje');
  const btnQGuardar = $('q-guardar');
  const okQ = $('q-ok');
  const errorQ = $('q-error');
  const vistaSellos = $('q-sellos');
  const vistaTexto = $('q-texto');
  const vistaMensaje = $('q-mensaje-vista');
  let qCargada = false; // la tarjeta vigente se carga al entrar a la sección, con la clave validada

  // Menú flotante: una sección a la vez. Solo se ven con la clave admin ya validada.
  // «#eliminar» (enlace viejo) abre Editar, donde ahora vive la zona de peligro.
  const SECCIONES = ['metricas', 'nueva', 'editar', 'quetzalitos', 'avisos'];
  const ALIAS = { eliminar: 'editar' };
  const seccionMetricas = $('metricas');
  const menu = $('menu');
  const botonesMenu = menu.querySelectorAll('[data-seccion]');
  const btnSalir = $('salir');
  const btnActualizar = $('actualizar');
  let adentro = false; // clave validada: hay menú y sección visible
  let seccion = 'metricas';
  // Dentro de Métricas: la tabla ('metricas') o las mensualidades ('mensualidades'). Solo en memoria.
  let vista = 'metricas';
  let filtroM = 'todas'; // filtro de Mensualidades: todas | vencida | pronto | ok
  let abierto = null; // formulario abierto en una tarjeta: { slug, modo: 'fecha' | 'quitar' }
  let enfocar = null; // slug de la tarjeta a la que devolver el foco tras guardar
  const vMetricas = $('v-metricas');
  const vMens = $('v-mensualidades');
  const botonesVista = document.querySelectorAll('[data-vista]');
  const botonesFiltro = document.querySelectorAll('[data-filtro]');
  const listaMens = $('lista-mens');
  const avisoMens = $('mens-aviso');
  const vacioMens = $('mens-vacio');
  const outCreada = $('m-creada');
  const outVence = $('m-vence');
  const outChip = $('m-chip');
  const btnPagar = $('m-pagar');
  const avisoPago = $('m-pago-aviso');

  function seccionDesdeHash() {
    let h = location.hash.slice(1);
    if (ALIAS[h]) h = ALIAS[h];
    if (h === 'mensualidades') return 'metricas';
    return SECCIONES.includes(h) ? h : 'metricas';
  }

  function vistaDesdeHash() {
    return location.hash.slice(1) === 'mensualidades' ? 'mensualidades' : 'metricas';
  }

  function pintarSeccion() {
    const todas = { metricas: seccionMetricas, nueva: seccionNueva, editar: seccionEditar, quetzalitos: seccionQ, avisos: $('avisos') };
    for (const s of SECCIONES) todas[s].classList.toggle('oculto', !adentro || s !== seccion);
    for (const b of botonesMenu) {
      const activa = b.dataset.seccion === seccion;
      b.classList.toggle('activo', activa);
      if (activa) b.setAttribute('aria-current', 'page');
      else b.removeAttribute('aria-current');
    }
    const enMens = adentro && seccion === 'metricas' && vista === 'mensualidades';
    vMetricas.classList.toggle('oculto', enMens);
    vMens.classList.toggle('oculto', !enMens);
    for (const b of botonesVista) b.setAttribute('aria-pressed', String(b.dataset.vista === vista));
  }

  // Cambia de sección (y de vista dentro de Métricas) y deja la elegida en el hash (sin llenar el historial).
  function irA(s, v) {
    const previa = seccion;
    seccion = SECCIONES.includes(s) ? s : 'metricas';
    vista = v === 'mensualidades' && seccion === 'metricas' ? 'mensualidades' : 'metricas';
    const destino = '#' + (vista === 'mensualidades' ? 'mensualidades' : seccion);
    if (location.hash !== destino) history.replaceState(null, '', destino);
    if (previa === 'editar' && seccion !== 'editar') { // una baja a medias no sigue esperando al cambiar de sección
      pendiente = null;
      cajaConfirmar.classList.add('oculto');
    }
    pintarSeccion();
    if (adentro && seccion === 'quetzalitos' && (previa !== 'quetzalitos' || !qCargada)) cargarQuetzalitos();
  }

  function mostrarAdmin(visible) {
    adentro = visible;
    form.classList.toggle('oculto', visible); // con la clave validada se oculta el formulario; la clave sigue solo en memoria
    menu.classList.toggle('oculto', !visible);
    document.body.classList.toggle('con-nav', visible);
    if (visible) {
      irA(seccionDesdeHash(), vistaDesdeHash());
    } else { // sin clave no queda una confirmación pendiente ni la tarjeta cargada
      qCargada = false;
      pendiente = null;
      cajaConfirmar.classList.add('oculto');
      pintarSeccion();
    }
  }

  function mostrarEstado(texto) {
    estado.textContent = texto || '';
    estado.classList.toggle('oculto', !texto);
  }

  function mostrarError(codigo) {
    errorEl.textContent = codigo ? Q.msg(codigo) : '';
    errorEl.classList.toggle('oculto', !codigo);
  }

  function celda(valor, clase) {
    const td = document.createElement('td');
    td.textContent = valor;
    if (clase) td.className = clase;
    return td;
  }

  // Chip de estado de la mensualidad: color según Q.vencimiento; el texto va con textContent.
  function pintarChip(el, dias) {
    const v = Q.vencimiento(dias);
    el.className = 'chip chip-' + v.estado;
    el.textContent = v.texto;
    return el;
  }

  function chipVenc(dias) {
    return pintarChip(document.createElement('span'), dias);
  }

  function celdaVence(f) {
    const td = celda('', 'col-texto');
    td.appendChild(chipVenc(f.dias_para_vencer));
    return td;
  }

  // Adopción = reclamos / ventas. Sin ventas no hay base para calcular.
  function adopcion(reclamos, ventas) {
    return ventas > 0 ? Math.min(100, Math.round((reclamos / ventas) * 100)) + ' %' : '—';
  }

  // Nombre tal como se ve en tablas y listas; «desactivada» solo si la fila lo indica.
  function etiqueta(f) {
    return f.cafeteria + (f.activa === false ? ' · desactivada' : '');
  }

  // La escuela va entre paréntesis solo si la cafetería tiene una (la escuela es opcional).
  function conEscuela(f) {
    return f.escuela ? ' (' + f.escuela + ')' : '';
  }

  function opciones(filas) {
    return filas.map((f) => {
      const o = document.createElement('option');
      o.value = f.slug;
      o.textContent = etiqueta(f) + conEscuela(f);
      return o;
    });
  }

  // Rellena la sección de edición con la cafetería elegida (nombre real, sin el texto «desactivada»).
  function rellenarEditar() {
    mostrarSlugEditar();
    const f = filasActuales.find((x) => x.slug === selMCual.value);
    inMNombre.value = f ? f.cafeteria : '';
    inMEscuela.value = f ? f.escuela : '';
    inMActiva.checked = f ? f.activa !== false : false;
    inMDistribuidor.checked = f ? f.distribuidor === true : false;
    inMTope.value = f ? (f.tope_hora ?? '') : '';
  }

  function pintar(filas) {
    const total = { ventas: 0, reclamos: 0, canjes: 0, tarjetas_nuevas: 0 };
    filasActuales = filas;
    cuerpo.replaceChildren();
    for (const f of filas) {
      total.ventas += f.ventas;
      total.reclamos += f.reclamos;
      total.canjes += f.canjes;
      total.tarjetas_nuevas += f.tarjetas_nuevas;
      const tr = document.createElement('tr');
      [etiqueta(f), f.escuela || '—', f.ventas, f.reclamos, adopcion(f.reclamos, f.ventas), f.canjes, f.tarjetas_nuevas, f.distribuidor === true ? 'Sí' : 'No']
        .forEach((v) => tr.appendChild(celda(v)));
      tr.appendChild(celda(Q.fecha(f.creada_en) || '—', 'col-texto'));
      tr.appendChild(celdaVence(f));
      cuerpo.appendChild(tr);
    }
    const tr = document.createElement('tr');
    tr.className = 'total';
    ['Total', '', total.ventas, total.reclamos, adopcion(total.reclamos, total.ventas), total.canjes, total.tarjetas_nuevas, '', '', '']
      .forEach((v) => tr.appendChild(celda(v)));
    cuerpo.appendChild(tr);
    tabla.classList.remove('oculto');
    // Sugerencias para el campo «Escuela»: las que ya existen (se puede escribir una nueva).
    listaEscuelas.replaceChildren(...[...new Set(filas.map((f) => f.escuela))].map((e) => {
      const o = document.createElement('option');
      o.value = e;
      return o;
    }));
    // Lista para la baja: se conserva la elegida si sigue existiendo.
    const previa = selCual.value;
    selCual.replaceChildren(...opciones(filas));
    if ([...selCual.options].some((o) => o.value === previa)) selCual.value = previa;
    btnBorrar.disabled = filas.length === 0;
    // Lista para editar: se conserva la elegida si sigue existiendo; el PIN escrito se borra si cambia la cafetería.
    const previaEditar = selMCual.value;
    selMCual.replaceChildren(...opciones(filas));
    if ([...selMCual.options].some((o) => o.value === previaEditar)) selMCual.value = previaEditar;
    if (selMCual.value !== previaEditar) inMPin.value = '';
    // Los campos se rellenan al cargar, al cambiar de cafetería y tras guardar; un refresco por alta o baja no pisa lo que se está escribiendo.
    if (selMCual.value !== previaEditar || rellenarTrasGuardar) {
      rellenarEditar();
      rellenarTrasGuardar = false;
    }
    pintarVencEditar();
    pintarMens();
  }

  // Editar: fechas y chip de la cafetería elegida (solo lectura; no toca los campos que se están escribiendo).
  function pintarVencEditar() {
    const f = filasActuales.find((x) => x.slug === selMCual.value);
    outCreada.textContent = (f && Q.fecha(f.creada_en)) || '—';
    outVence.textContent = (f && Q.fecha(f.vence_en)) || '—';
    pintarChip(outChip, f ? f.dias_para_vencer : null);
    btnPagar.disabled = !f;
  }

  // Mensualidades: contadores, lista filtrada y tarjetas ordenadas por días para vencer (sin cobro, al final).
  function pintarMens() {
    const cont = { vencida: 0, pronto: 0, ok: 0 };
    for (const f of filasActuales) {
      const e = Q.vencimiento(f.dias_para_vencer).estado;
      if (e in cont) cont[e]++;
    }
    $('c-vencida').textContent = cont.vencida;
    $('c-pronto').textContent = cont.pronto;
    $('c-ok').textContent = cont.ok;
    $('c-todas').textContent = filasActuales.length;
    for (const b of botonesFiltro) b.setAttribute('aria-pressed', String(b.dataset.filtro === filtroM));
    const sinDias = (f) => f.dias_para_vencer === null || f.dias_para_vencer === undefined;
    const ordenadas = filasActuales.slice().sort((a, b) => {
      if (sinDias(a) || sinDias(b)) return sinDias(a) - sinDias(b);
      return a.dias_para_vencer - b.dias_para_vencer;
    });
    const visibles = ordenadas.filter((f) => filtroM === 'todas' || Q.vencimiento(f.dias_para_vencer).estado === filtroM);
    listaMens.replaceChildren(...visibles.map(tarjetaMens));
    vacioMens.classList.toggle('oculto', visibles.length > 0);
    if (enfocar) {
      for (const li of listaMens.children) {
        if (li.dataset.slug === enfocar) { li.querySelector('h3').focus({ preventScroll: true }); break; }
      }
      enfocar = null;
    }
  }

  function dato(termino, valor) {
    const div = document.createElement('div');
    const dt = document.createElement('dt');
    dt.textContent = termino;
    const dd = document.createElement('dd');
    dd.textContent = valor;
    div.append(dt, dd);
    return div;
  }

  function botonAcc(texto, clases, alCliquear) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = clases;
    b.textContent = texto;
    b.addEventListener('click', alCliquear);
    return b;
  }

  function tarjetaMens(f) {
    const li = document.createElement('li');
    li.className = 'tarjeta-mens';
    li.dataset.slug = f.slug;

    const cab = document.createElement('div');
    cab.className = 'cab-mens';
    const h = document.createElement('h3');
    h.tabIndex = -1;
    h.textContent = etiqueta(f) + conEscuela(f);
    cab.append(h, chipVenc(f.dias_para_vencer));

    const datos = document.createElement('dl');
    datos.className = 'datos-mens';
    datos.append(dato('Creada', Q.fecha(f.creada_en) || '—'), dato('Vence', Q.fecha(f.vence_en) || '—'));

    const acciones = document.createElement('div');
    acciones.className = 'acciones-mens';
    acciones.append(
      botonAcc('Registrar pago (+1 mes)', 'btn btn-rosa btn-chico', () => cambiarVencimiento(f.slug, null, 1, li)),
      botonAcc('Elegir fecha', 'btn btn-fantasma btn-chico', () => {
        abierto = { slug: f.slug, modo: 'fecha' };
        pintarMens();
        const inp = $('mens-fecha');
        if (inp) inp.focus();
      }),
      botonAcc('Quitar seguimiento', 'btn btn-fantasma btn-chico', () => {
        abierto = { slug: f.slug, modo: 'quitar' };
        pintarMens();
        const no = $('mens-quitar-no');
        if (no) no.focus();
      })
    );
    li.append(cab, datos, acciones);

    if (abierto && abierto.slug === f.slug && abierto.modo === 'fecha') {
      const form = document.createElement('form');
      form.className = 'form-fecha';
      form.autocomplete = 'off';
      const lb = document.createElement('label');
      lb.htmlFor = 'mens-fecha';
      lb.textContent = 'Nueva fecha de vencimiento';
      const inp = document.createElement('input');
      inp.type = 'date';
      inp.id = 'mens-fecha';
      inp.className = 'campo campo-texto';
      inp.required = true;
      const fila = document.createElement('div');
      fila.className = 'fila-acc';
      const guardar = document.createElement('button');
      guardar.type = 'submit';
      guardar.className = 'btn btn-rosa btn-chico';
      guardar.textContent = 'Guardar';
      fila.append(guardar, botonAcc('Cancelar', 'btn btn-fantasma btn-chico', () => { abierto = null; pintarMens(); }));
      form.append(lb, inp, fila);
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        if (!inp.value) { avisar(avisoMens, 'Elige una fecha.', true); inp.focus(); return; }
        cambiarVencimiento(f.slug, inp.value, null, li);
      });
      li.appendChild(form);
    } else if (abierto && abierto.slug === f.slug && abierto.modo === 'quitar') {
      const caja = document.createElement('div');
      caja.className = 'confirmar-quitar';
      const p = document.createElement('p');
      p.textContent = '¿Quitar el seguimiento de «' + etiqueta(f) + '»? Dejará de tener fecha de vencimiento.';
      const no = botonAcc('Cancelar', 'btn btn-fantasma btn-chico', () => { abierto = null; pintarMens(); });
      no.id = 'mens-quitar-no';
      const si = botonAcc('Sí, quitar', 'btn btn-peligro relleno btn-chico', () => cambiarVencimiento(f.slug, null, null, li));
      const fila = document.createElement('div');
      fila.className = 'fila-acc';
      fila.append(si, no);
      caja.append(p, fila);
      li.appendChild(caja);
    }
    return li;
  }

  // Aviso breve con espacio reservado; «mal» lo pinta en color de error.
  function avisar(el, texto, mal) {
    el.className = 'aviso-mens' + (mal ? ' mal' : '');
    el.textContent = texto;
  }

  // Única llamada a set_vencimiento: vence (AAAA-MM-DD), meses (1-24) o ambos null para quitar el seguimiento.
  function ajustarVencimiento(slug, vence, meses) {
    return Q.rpc('set_vencimiento', { p_clave: clave, p_slug: slug, p_vence: vence, p_meses: meses });
  }

  // Aplica el resultado en la fila local y repinta tabla, tarjetas y Editar, sin volver a pedir las métricas.
  function aplicarVencimiento(slug, res) {
    filasActuales = filasActuales.map((x) => (x.slug === slug
      ? { ...x, vence_en: res.vence_en, dias_para_vencer: res.dias_para_vencer } : x));
    pintar(filasActuales);
  }

  function textoVence(res) {
    return res.vence_en ? 'Vence ' + Q.fecha(res.vence_en) + '.' : 'Sin seguimiento de mensualidad.';
  }

  async function cambiarVencimiento(slug, vence, meses, li) {
    if (!clave) return;
    for (const el of li.querySelectorAll('button, input')) el.disabled = true;
    avisar(avisoMens, 'Guardando…', false);
    const res = await ajustarVencimiento(slug, vence, meses);
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') { claveInvalidaQ(); return; }
      if (codigo === 'red') {
        avisar(avisoMens, 'No se pudo confirmar la respuesta. Se vuelve a cargar la lista para ver el estado real.', true);
        consultar(true);
        return;
      }
      avisar(avisoMens, Q.msg(codigo), true);
      if (codigo === 'no_existe') consultar(true);
      else pintarMens();
      return;
    }
    abierto = null;
    enfocar = slug;
    aplicarVencimiento(slug, res);
    avisar(avisoMens, '«' + res.cafeteria + '»: ' + textoVence(res), false);
  }

  // Editar: «Registrar pago (+1 mes)» usa la misma llamada que las tarjetas.
  btnPagar.addEventListener('click', async () => {
    const f = filasActuales.find((x) => x.slug === selMCual.value);
    if (!clave || !f) return;
    btnPagar.disabled = true;
    avisar(avisoPago, 'Guardando…', false);
    const res = await ajustarVencimiento(f.slug, null, 1);
    btnPagar.disabled = false;
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') { claveInvalidaQ(); return; }
      avisar(avisoPago, codigo === 'red' ? 'No se pudo confirmar la respuesta. Revisa la fecha antes de intentar de nuevo.' : Q.msg(codigo), true);
      if (codigo === 'red' || codigo === 'no_existe') consultar(true);
      return;
    }
    aplicarVencimiento(f.slug, res);
    avisar(avisoPago, '«' + res.cafeteria + '»: pago registrado. ' + textoVence(res), false);
  });

  // sinParpadeo: al refrescar tras un alta la tabla se queda a la vista, para que la página no brinque ni se pierda el aviso del PIN.
  async function consultar(sinParpadeo) {
    if (!clave) return;
    const id = ++pedido;
    boton.disabled = true;
    if (!sinParpadeo) tabla.classList.add('oculto');
    mostrarError('');
    if (!sinParpadeo) mostrarEstado('Cargando métricas…');

    const res = await Q.rpc('metricas', { p_clave: clave, p_dias: dias });
    if (id !== pedido) return;

    boton.disabled = false;
    mostrarEstado('');
    if (!res || !res.ok) {
      tabla.classList.add('oculto');
      if (res && res.error === 'clave_invalida') { // obliga a volver a escribirla
        clave = null;
        mostrarAdmin(false);
      }
      mostrarError((res && res.error) || 'red');
      return;
    }
    inputClave.value = ''; // la clave ya está en memoria; no la dejamos en pantalla
    pintar(res.filas || []);
    mostrarAdmin(true);
  }

  // Etiqueta NFC: crea la llave en el servidor y muestra llave + URL para grabarlas (la llave no se vuelve a ver).
  function campoCopiar(rotulo, valor) {
    const fila = document.createElement('div');
    fila.className = 'fila-pin';
    const inp = document.createElement('input');
    inp.className = 'campo';
    inp.readOnly = true;
    inp.value = valor;
    inp.setAttribute('aria-label', rotulo);
    inp.style.letterSpacing = 'normal';
    inp.style.fontSize = '.8rem';
    const b = botonAcc('Copiar', 'btn btn-chico btn-fantasma', () => {
      navigator.clipboard.writeText(valor).then(() => { b.textContent = 'Copiado'; }, () => inp.select());
    });
    fila.append(inp, b);
    return fila;
  }

  // Código de la cafetería (slug) con botón de copiar, para pegarlo en la app Etiquetas Ollin.
  function mostrarSlug(destino, slug, texto) {
    const p = document.createElement('p');
    p.textContent = texto;
    destino.replaceChildren(p, campoCopiar('Código de la cafetería', slug));
    destino.classList.remove('oculto');
  }
  function mostrarSlugEditar() {
    const el = $('m-nfc-res');
    if (selMCual.value) mostrarSlug(el, selMCual.value, 'Código de esta cafetería:');
    else el.replaceChildren();
  }

  // PIN de 6 dígitos sin sesgo: 4 294 800 000 = 4772 × 900 000 (se descarta lo que sobra de los 2^32 valores).
  function pinAleatorio() {
    const n = new Uint32Array(1);
    do { crypto.getRandomValues(n); } while (n[0] >= 4294800000);
    return String(100000 + (n[0] % 900000));
  }

  $('n-generar').addEventListener('click', () => {
    inPin.value = pinAleatorio();
  });

  $('m-generar').addEventListener('click', () => {
    inMPin.value = pinAleatorio();
  });

  selMCual.addEventListener('change', () => {
    inMPin.value = ''; // un PIN escrito para una cafetería no se aplica a otra
    rellenarEditar();
    pintarVencEditar();
    mostrarSlugEditar();
    avisar(avisoPago, '', false);
  });

  // Avisos a todas las tarjetas de Quetzalitos (la clave admin sigue solo en memoria).
  $('av-g-enviar').addEventListener('click', async () => {
    const titulo = $('av-g-titulo').value.trim();
    const cuerpo = $('av-g-cuerpo').value.trim();
    const msg = $('av-g-msg');
    const mostrarMsg = (texto, tipo) => { msg.textContent = texto; msg.className = tipo === 'error' ? 'error' : 'aviso'; };
    if (!clave) return;
    if (!titulo || !cuerpo) return mostrarMsg('Escribe un título y un mensaje.', 'error');
    const boton = $('av-g-enviar');
    boton.disabled = true;
    mostrarMsg('Enviando…', 'aviso');
    const r = await Q.rpc('enviar_aviso_general', { p_clave: clave, p_titulo: titulo, p_cuerpo: cuerpo });
    if (!r || !r.ok) {
      boton.disabled = false;
      if (r && r.error === 'clave_invalida') { clave = null; mostrarAdmin(false); return mostrarError(r.error); }
      return mostrarMsg(Q.msg((r && r.error) || 'red'), 'error');
    }
    const e = await Q.enviarAviso(r.aviso);
    boton.disabled = false;
    if (!e.ok) return mostrarMsg('El aviso quedó guardado, pero no se envió. Intenta de nuevo en unos minutos.', 'error');
    mostrarMsg('Aviso enviado a ' + e.enviados + ' celular' + (e.enviados === 1 ? '' : 'es') + '.', 'aviso');
    $('av-g-titulo').value = '';
    $('av-g-cuerpo').value = '';
  });

  formNueva.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!clave) return;
    const pin = inPin.value;
    okNueva.classList.add('oculto');
    slugNueva.classList.add('oculto');
    errorNueva.classList.add('oculto');
    okElim.classList.add('oculto');
    errorElim.classList.add('oculto');
    errorEditar.classList.add('oculto'); // el aviso de una edición (puede llevar un PIN que no se vuelve a ver) se queda
    btnCrear.disabled = true;
    const res = await Q.rpc('crear_cafeteria', {
      p_clave: clave, p_nombre: inNombre.value.trim(), p_escuela: inEscuela.value.trim(), p_pin: pin
    });
    btnCrear.disabled = false;
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') {
        clave = null;
        mostrarAdmin(false);
        tabla.classList.add('oculto');
        mostrarError(codigo);
        return;
      }
      errorNueva.textContent = codigo === 'red'
        ? 'No se pudo confirmar la respuesta. Revisa la tabla: si la cafetería aparece, ya se creó; no la repitas.'
        : Q.msg(codigo);
      errorNueva.classList.remove('oculto');
      if (codigo === 'red') consultar(true);
      return;
    }
    const negrita = document.createElement('strong');
    negrita.textContent = pin;
    okNueva.replaceChildren(
      'Cafetería «' + res.cafeteria + '»' + conEscuela(res) + ' creada. PIN: ', negrita,
      '. Anótalo y entrégalo al personal de caja: no se puede volver a consultar.'
    );
    ultimaAlta = res.slug;
    okNueva.classList.remove('oculto');
    okNueva.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    mostrarSlug(slugNueva, res.slug, 'Código para la app Etiquetas Ollin:');
    inNombre.value = '';
    inPin.value = ''; // la escuela se queda: suele darse de alta más de una cafetería seguida
    consultar(true);
  });

  // Baja en dos pasos: elegir y confirmar. La baja usa lo elegido al pulsar «Eliminar…», aunque la lista cambie después.
  const cuenta = (n, uno, varios) => n + ' ' + (n === 1 ? uno : varios);

  formEliminar.addEventListener('submit', (e) => {
    e.preventDefault();
    const opcion = selCual.selectedOptions[0];
    if (!clave || !opcion) return;
    pendiente = { slug: opcion.value, texto: opcion.textContent };
    preguntaEl.textContent = '¿Eliminar «' + opcion.textContent + '»? No se puede deshacer y su PIN dejará de funcionar.';
    okElim.classList.add('oculto');
    errorElim.classList.add('oculto');
    errorEditar.classList.add('oculto');
    cajaConfirmar.classList.remove('oculto');
    btnNo.focus(); // el foco cae en «Cancelar»: confirmar exige un toque deliberado
  });

  btnNo.addEventListener('click', () => {
    pendiente = null;
    cajaConfirmar.classList.add('oculto');
  });

  btnSi.addEventListener('click', async () => {
    if (!clave || !pendiente) return;
    const { slug, texto } = pendiente;
    btnSi.disabled = true;
    btnNo.disabled = true;
    btnBorrar.disabled = true; // sin otra baja mientras esta viaja
    const res = await Q.rpc('eliminar_cafeteria', { p_clave: clave, p_slug: slug });
    btnSi.disabled = false;
    btnNo.disabled = false;
    btnBorrar.disabled = selCual.options.length === 0;
    pendiente = null;
    cajaConfirmar.classList.add('oculto');
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') {
        clave = null;
        mostrarAdmin(false);
        tabla.classList.add('oculto');
        mostrarError(codigo);
        return;
      }
      if (codigo === 'con_historial') {
        errorElim.textContent = '«' + texto + '» ya tiene ' + cuenta(res.ventas, 'venta', 'ventas') + ', '
          + cuenta(res.reclamos, 'sello', 'sellos') + ' y ' + cuenta(res.canjes, 'canje', 'canjes')
          + '. No se puede eliminar sin borrar el historial de las tarjetas de los clientes; si ya no se usa, desactívala en «Editar cafetería».';
      } else if (codigo === 'red') {
        errorElim.textContent = 'No se pudo confirmar la respuesta. Revisa la tabla: si la cafetería ya no aparece, se eliminó.';
      } else {
        errorElim.textContent = Q.msg(codigo);
      }
      errorElim.classList.remove('oculto');
      if (codigo === 'red' || codigo === 'no_existe') consultar(true);
      return;
    }
    // El aviso del PIN solo se quita si era el de esta misma cafetería: ese PIN no se puede volver a consultar.
    if (slug === ultimaAlta) okNueva.classList.add('oculto');
    if (slug === ultimaEdicionPin) {
      okEditar.classList.add('oculto');
      ultimaEdicionPin = null;
    }
    okElim.textContent = 'Cafetería «' + res.cafeteria + '»' + conEscuela(res) + ' eliminada.';
    okElim.classList.remove('oculto');
    consultar(true);
  });

  // Edición: solo viaja lo que se cambia (los null no tocan nada). El PIN nuevo se muestra una sola vez, como en el alta.
  formEditar.addEventListener('submit', async (e) => {
    e.preventDefault();
    const opcion = selMCual.selectedOptions[0];
    if (!clave || !opcion) return;
    const slug = opcion.value;
    const pin = inMPin.value || null;
    errorEditar.classList.add('oculto'); // el aviso anterior (puede llevar un PIN sin anotar) se queda hasta que haya otro resultado
    errorNueva.classList.add('oculto');
    okElim.classList.add('oculto');
    errorElim.classList.add('oculto');
    // El distribuidor es un paso aparte: se llama si la casilla cambió, aunque no cambie ningún otro dato.
    const filaActual = filasActuales.find((x) => x.slug === slug);
    const valorDist = inMDistribuidor.checked;
    const cambioDist = !!filaActual && valorDist !== (filaActual.distribuidor === true);
    btnGuardar.disabled = true;
    const res = await Q.rpc('editar_cafeteria', {
      p_clave: clave, p_slug: slug, p_nombre: inMNombre.value.trim(), p_escuela: inMEscuela.value.trim(),
      p_pin: pin, p_activa: inMActiva.checked, p_tope_hora: Number(inMTope.value)
    });
    let resDist = null;
    if (cambioDist && (!res || res.error !== 'clave_invalida')) {
      resDist = await Q.rpc('set_distribuidor', { p_clave: clave, p_slug: slug, p_valor: valorDist });
    }
    btnGuardar.disabled = false;
    const errEdit = !res || !res.ok ? ((res && res.error) || 'red') : null;
    const errDist = resDist && !resDist.ok ? (resDist.error || 'red') : null;
    if (errEdit === 'clave_invalida' || errDist === 'clave_invalida') {
      clave = null;
      mostrarAdmin(false);
      tabla.classList.add('oculto');
      mostrarError('clave_invalida');
      return;
    }
    const distOk = !!resDist && resDist.ok;
    const reintentar = ['red', 'no_existe'];
    // Cada paso informa por su cuenta: un fallo de uno no oculta el éxito del otro.
    const errores = [];
    if (errEdit) {
      errores.push(errEdit === 'red'
        ? 'No se pudo confirmar la respuesta. Revisa la tabla e inténtalo de nuevo.'
        : Q.msg(errEdit));
    }
    if (errDist) {
      const textoDist = errDist === 'red' ? 'no se pudo confirmar la respuesta.' : Q.msg(errDist);
      errores.push((errEdit ? 'Tampoco se pudo cambiar distribuidor: ' : 'Datos guardados, pero no se pudo cambiar distribuidor: ') + textoDist);
    }
    if (errores.length) {
      errorEditar.textContent = errores.join(' ');
      errorEditar.classList.remove('oculto');
    }
    if (!errEdit) {
      const partes = ['Cambios guardados en «' + res.cafeteria + '»' + conEscuela(res) + '.'];
      if (distOk) partes.push(' Distribuidor: ' + (valorDist ? 'sí' : 'no') + '.');
      if (res.pin_cambiado) {
        const negrita = document.createElement('strong');
        negrita.textContent = pin;
        partes.push(' PIN nuevo: ', negrita, '. Anótalo y entrégalo al personal de caja: no se puede volver a consultar.');
      }
      if (!res.pin_cambiado && ultimaEdicionPin !== null && !okEditar.classList.contains('oculto')) {
        okEditar.append(document.createElement('br'), ...partes); // hay un PIN sin anotar a la vista: se añade debajo, no se borra
      } else {
        okEditar.replaceChildren(...partes);
        ultimaEdicionPin = res.pin_cambiado ? slug : null;
      }
      inMPin.value = '';
      okEditar.classList.remove('oculto');
      okEditar.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    } else if (distOk) {
      // Los datos no se guardaron, pero el distribuidor sí: se avisa sin tocar un PIN pendiente de anotar.
      const aviso = 'Distribuidor de «' + resDist.cafeteria + '» actualizado.';
      if (okEditar.classList.contains('oculto')) okEditar.textContent = aviso;
      else okEditar.append(document.createElement('br'), aviso);
      okEditar.classList.remove('oculto');
    }
    if (!errEdit || distOk) rellenarTrasGuardar = true;
    if (!errEdit || distOk || reintentar.includes(errEdit) || reintentar.includes(errDist)) consultar(true);
  });

  // Tarjeta Quetzalitos: solo los valores; el diseño de la tarjeta vive en el CSS del cliente.
  let pedidoQ = 0;

  function claveInvalidaQ() {
    clave = null;
    mostrarAdmin(false);
    tabla.classList.add('oculto');
    mostrarError('clave_invalida');
  }

  function pintarVistaQ() {
    const meta = Math.min(50, Math.max(0, Math.floor(Number(inQMeta.value)) || 0));
    const palabra = inQUnidad.value.trim() || 'sellos';
    const premio = inQPremio.value.trim();
    vistaSellos.className = 'sellos' + (meta > 6 ? ' cinco' : '');
    const piezas = [];
    for (let i = 0; i < meta; i++) {
      const s = document.createElement('div');
      s.className = 'sello';
      piezas.push(s);
    }
    const p = document.createElement('div');
    p.className = 'sello premio';
    p.textContent = premio || 'Premio';
    piezas.push(p);
    vistaSellos.replaceChildren(...piezas);
    vistaTexto.textContent = 'Llevas 0 de ' + meta + ' ' + palabra + (premio ? ' · ' + premio : '');
    const msg = inQMensaje.value.trim();
    vistaMensaje.textContent = msg;
    vistaMensaje.classList.toggle('oculto', !msg);
  }

  function pintarQ(c) {
    inQMeta.value = c.meta;
    inQUnidad.value = c.unidad;
    inQPremio.value = c.premio;
    inQMensaje.value = c.mensaje || '';
    pintarVistaQ();
  }

  async function cargarQuetzalitos() {
    if (!clave) return;
    const id = ++pedidoQ;
    okQ.classList.add('oculto');
    errorQ.classList.add('oculto');
    btnQGuardar.disabled = true;
    const res = await Q.rpc('quetzalitos_config', { p_clave: clave }); // sin p_* devuelve lo vigente
    if (id !== pedidoQ) return;
    btnQGuardar.disabled = false;
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') { claveInvalidaQ(); return; }
      errorQ.textContent = Q.msg(codigo);
      errorQ.classList.remove('oculto');
      return;
    }
    qCargada = true;
    pintarQ(res.config);
  }

  formQ.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!clave) return;
    okQ.classList.add('oculto');
    errorQ.classList.add('oculto');
    btnQGuardar.disabled = true;
    const res = await Q.rpc('quetzalitos_config', {
      p_clave: clave, p_meta: Number(inQMeta.value), p_unidad: inQUnidad.value.trim(),
      p_premio: inQPremio.value.trim(), p_mensaje: inQMensaje.value.trim() // «» borra el mensaje
    });
    btnQGuardar.disabled = false;
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') { claveInvalidaQ(); return; }
      if (codigo === 'red') qCargada = false; // no se sabe si se guardó: la próxima vez se vuelve a cargar lo vigente
      errorQ.textContent = codigo === 'red'
        ? 'No se pudo confirmar la respuesta. Revisa la tarjeta antes de guardar otra vez.'
        : Q.msg(codigo);
      errorQ.classList.remove('oculto');
      return;
    }
    qCargada = true;
    pintarQ(res.config);
    okQ.textContent = 'Tarjeta Quetzalitos guardada.';
    okQ.classList.remove('oculto');
    okQ.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  });

  [inQMeta, inQUnidad, inQPremio, inQMensaje].forEach((el) => el.addEventListener('input', pintarVistaQ));

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!inputClave.value) return;
    clave = inputClave.value;
    consultar();
  });

  selPeriodo.addEventListener('change', () => {
    dias = selPeriodo.value ? Number(selPeriodo.value) : null;
    consultar();
  });

  btnActualizar.addEventListener('click', async () => {
    btnActualizar.disabled = true;
    await consultar();
    btnActualizar.disabled = false;
  });

  for (const b of botonesMenu) {
    b.addEventListener('click', () => irA(b.dataset.seccion));
  }

  // Métricas | Mensualidades: cambia la vista dentro de Métricas (queda en el hash).
  for (const b of botonesVista) {
    b.addEventListener('click', () => irA('metricas', b.dataset.vista));
  }

  // Contadores de Mensualidades: filtran la lista (el filtro vive solo en memoria).
  for (const b of botonesFiltro) {
    b.addEventListener('click', () => {
      filtroM = b.dataset.filtro;
      abierto = null;
      pintarMens();
    });
  }

  // Volver regresa a la pantalla principal (caja); la clave solo vive en memoria y se olvida al salir de esta página.
  btnSalir.addEventListener('click', () => {
    clave = null;
    location.href = '../caja/';
  });

  window.addEventListener('hashchange', () => irA(seccionDesdeHash(), vistaDesdeHash()));

  // Al cargar: sin clave validada no hay menú ni sección visible; solo se recuerda cuál abrir.
  irA(seccionDesdeHash(), vistaDesdeHash());
})();
