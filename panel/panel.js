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

  function pintar(filas) {
    const total = { ventas: 0, reclamos: 0, canjes: 0, tarjetas_nuevas: 0 };
    cuerpo.replaceChildren();
    for (const f of filas) {
      total.ventas += f.ventas;
      total.reclamos += f.reclamos;
      total.canjes += f.canjes;
      total.tarjetas_nuevas += f.tarjetas_nuevas;
      const tr = document.createElement('tr');
      [f.cafeteria, f.escuela, f.ventas, f.reclamos, adopcion(f.reclamos, f.ventas), f.canjes, f.tarjetas_nuevas]
        .forEach((v) => tr.appendChild(celda(v)));
      cuerpo.appendChild(tr);
    }
    const tr = document.createElement('tr');
    tr.className = 'total';
    ['Total', '', total.ventas, total.reclamos, adopcion(total.reclamos, total.ventas), total.canjes, total.tarjetas_nuevas]
      .forEach((v) => tr.appendChild(celda(v)));
    cuerpo.appendChild(tr);
    tabla.classList.remove('oculto');
  }

  async function consultar() {
    if (!clave) return;
    const id = ++pedido;
    boton.disabled = true;
    tabla.classList.add('oculto');
    mostrarError('');
    mostrarEstado('Cargando métricas…');

    const res = await Q.rpc('metricas', { p_clave: clave, p_dias: dias });
    if (id !== pedido) return;

    boton.disabled = false;
    mostrarEstado('');
    if (!res || !res.ok) {
      if (res && res.error === 'clave_invalida') clave = null; // obliga a volver a escribirla
      mostrarError((res && res.error) || 'red');
      return;
    }
    inputClave.value = ''; // la clave ya está en memoria; no la dejamos en pantalla
    pintar(res.filas || []);
  }

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
