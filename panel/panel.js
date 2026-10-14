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
  const listaEscuelas = $('escuelas');
  const seccionEliminar = $('eliminar');
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
  const inMTope = $('m-tope');
  const btnGuardar = $('m-guardar');
  const okEditar = $('m-ok');
  const errorEditar = $('m-error');
  let filasActuales = []; // últimas filas de métricas: alimentan la sección de edición
  let rellenarTrasGuardar = false; // el siguiente refresco vuelve a llenar el formulario de edición con datos del servidor

  // Las secciones de alta y baja solo se ven con la clave admin ya validada.
  function mostrarAdmin(visible) {
    seccionNueva.classList.toggle('oculto', !visible);
    seccionEliminar.classList.toggle('oculto', !visible);
    seccionEditar.classList.toggle('oculto', !visible);
    if (!visible) { // sin clave no queda una confirmación pendiente
      pendiente = null;
      cajaConfirmar.classList.add('oculto');
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

  function celda(valor) {
    const td = document.createElement('td');
    td.textContent = valor;
    return td;
  }

  // Adopción = reclamos / ventas. Sin ventas no hay base para calcular.
  function adopcion(reclamos, ventas) {
    return ventas > 0 ? Math.round((reclamos / ventas) * 100) + ' %' : '—';
  }

  // Nombre tal como se ve en tablas y listas; «desactivada» solo si la fila lo indica.
  function etiqueta(f) {
    return f.cafeteria + (f.activa === false ? ' · desactivada' : '');
  }

  function opciones(filas) {
    return filas.map((f) => {
      const o = document.createElement('option');
      o.value = f.slug;
      o.textContent = etiqueta(f) + ' (' + f.escuela + ')';
      return o;
    });
  }

  // Rellena la sección de edición con la cafetería elegida (nombre real, sin el texto «desactivada»).
  function rellenarEditar() {
    const f = filasActuales.find((x) => x.slug === selMCual.value);
    inMNombre.value = f ? f.cafeteria : '';
    inMEscuela.value = f ? f.escuela : '';
    inMActiva.checked = f ? f.activa !== false : false;
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
      [etiqueta(f), f.escuela, f.ventas, f.reclamos, adopcion(f.reclamos, f.ventas), f.canjes, f.tarjetas_nuevas]
        .forEach((v) => tr.appendChild(celda(v)));
      cuerpo.appendChild(tr);
    }
    const tr = document.createElement('tr');
    tr.className = 'total';
    ['Total', '', total.ventas, total.reclamos, adopcion(total.reclamos, total.ventas), total.canjes, total.tarjetas_nuevas]
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
  }

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
  });

  formNueva.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!clave) return;
    const pin = inPin.value;
    okNueva.classList.add('oculto');
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
      'Cafetería «' + res.cafeteria + '» (' + res.escuela + ') creada. PIN: ', negrita,
      '. Anótalo y entrégalo al personal de caja: no se puede volver a consultar.'
    );
    ultimaAlta = res.slug;
    okNueva.classList.remove('oculto');
    okNueva.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
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
    okElim.textContent = 'Cafetería «' + res.cafeteria + '» (' + res.escuela + ') eliminada.';
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
    btnGuardar.disabled = true;
    const res = await Q.rpc('editar_cafeteria', {
      p_clave: clave, p_slug: slug, p_nombre: inMNombre.value.trim(), p_escuela: inMEscuela.value.trim(),
      p_pin: pin, p_activa: inMActiva.checked, p_tope_hora: Number(inMTope.value)
    });
    btnGuardar.disabled = false;
    if (!res || !res.ok) {
      const codigo = (res && res.error) || 'red';
      if (codigo === 'clave_invalida') {
        clave = null;
        mostrarAdmin(false);
        tabla.classList.add('oculto');
        mostrarError(codigo);
        return;
      }
      errorEditar.textContent = codigo === 'red'
        ? 'No se pudo confirmar la respuesta. Revisa la tabla e inténtalo de nuevo.'
        : Q.msg(codigo);
      errorEditar.classList.remove('oculto');
      if (codigo === 'red' || codigo === 'no_existe') consultar(true);
      return;
    }
    const partes = ['Cambios guardados en «' + res.cafeteria + '» (' + res.escuela + ').'];
    if (res.pin_cambiado) {
      const negrita = document.createElement('strong');
      negrita.textContent = pin;
      partes.push(' PIN nuevo: ', negrita, '. Anótalo y entrégalo al personal de caja: no se puede volver a consultar.');
    }
    if (!res.pin_cambiado && ultimaEdicionPin !== null && !okEditar.classList.contains('oculto')) {
      okEditar.append(document.createElement('br'), partes[0]); // hay un PIN sin anotar a la vista: se añade debajo, no se borra
    } else {
      okEditar.replaceChildren(...partes);
      ultimaEdicionPin = res.pin_cambiado ? slug : null;
    }
    inMPin.value = '';
    okEditar.classList.remove('oculto');
    okEditar.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    rellenarTrasGuardar = true;
    consultar(true);
  });

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
})();
