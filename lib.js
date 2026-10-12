// Cliente compartido: window.Q.rpc llama funciones PostgREST; window.Q.msg traduce códigos de error.
(function () {
  "use strict";

  var MENSAJES = {
    pin_invalido: "PIN incorrecto.",
    bloqueado: "Demasiados intentos. Espera unos minutos y vuelve a intentar.",
    tope_hora: "Ya se hicieron muchos QR en esta hora. Intenta más tarde.",
    token_invalido: "Este QR no es válido. Pide uno nuevo a la cajera.",
    token_usado: "Este QR ya fue usado.",
    token_vencido: "Este QR ya venció. Pide uno nuevo a la cajera.",
    sello_reciente: "Ya tienes un sello de esta cafetería hace poco. Vuelve en unos minutos.",
    tarjeta_invalida: "No encontramos tu tarjeta en este teléfono.",
    faltan_sellos: "Todavía no completas los sellos para el premio.",
    canje_invalido: "Código de canje incorrecto.",
    canje_usado: "Este código de canje ya fue usado.",
    canje_vencido: "El código de canje venció. Pide uno nuevo.",
    clave_invalida: "Clave incorrecta.",
    red: "Sin conexión. Revisa tu internet e intenta de nuevo."
  };
  var GENERICO = "Algo salió mal. Intenta de nuevo.";

  window.Q = {
    // Siempre resuelve con un objeto JSON; los fallos de red, HTTP o tiempo agotado (12 s) salen como {ok:false, error:"red"}.
    rpc: function (fn, args) {
      var key = QUETZALITO.key;
      var cabeceras = { "Content-Type": "application/json", apikey: key };
      if (key.indexOf("eyJ") === 0) cabeceras.Authorization = "Bearer " + key;
      var control = new AbortController();
      var tiempo = setTimeout(function () { control.abort(); }, 12000);
      return fetch(QUETZALITO.url + "/rest/v1/rpc/" + fn, {
        method: "POST",
        headers: cabeceras,
        body: JSON.stringify(args || {}),
        signal: control.signal
      })
        .then(function (res) {
          return res.ok ? res.json() : { ok: false, error: "red" };
        })
        .catch(function () {
          return { ok: false, error: "red" };
        })
        .then(function (r) {
          clearTimeout(tiempo);
          return r;
        });
    },

    msg: function (codigo) {
      return Object.prototype.hasOwnProperty.call(MENSAJES, codigo) ? MENSAJES[codigo] : GENERICO;
    }
  };
})();
