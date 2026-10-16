// Cliente compartido: window.Q.rpc llama funciones PostgREST; window.Q.msg traduce códigos de error.
(function () {
  "use strict";

  var MENSAJES = {
    pin_invalido: "PIN incorrecto.",
    bloqueado: "Demasiados intentos. Espera unos minutos y vuelve a intentar.",
    tope_hora: "Ya se hicieron muchos QR en esta hora. Intenta más tarde.",
    token_invalido: "Este QR no es válido. Pide uno nuevo en caja.",
    token_usado: "Este QR ya fue usado.",
    token_vencido: "Este QR ya venció. Pide uno nuevo en caja.",
    sello_reciente: "Ya tienes un sello de esta cafetería hace poco. Vuelve en unos minutos.",
    tarjeta_invalida: "No encontramos tu tarjeta en este teléfono.",
    faltan_sellos: "Todavía no completas los sellos para el premio.",
    canje_invalido: "Código de canje incorrecto.",
    canje_usado: "Este código de canje ya fue usado.",
    canje_vencido: "El código de canje venció. Pide uno nuevo.",
    clave_invalida: "Clave incorrecta.",
    datos_invalidos: "Revisa el nombre (de 2 a 80 caracteres) y la escuela (opcional, hasta 40).",
    pin_formato: "El PIN debe tener exactamente 6 números.",
    pin_repetido: "Ese PIN ya lo usa otra cafetería. Elige otro (si acabas de crearla, revisa la tabla).",
    tope_invalido: "El máximo de QR por hora debe ser un número entero de 1 a 1000.",
    no_existe: "Esa cafetería ya no existe. Revisa la tabla.",
    con_historial: "Esa cafetería ya tiene ventas, sellos o canjes y no se puede eliminar.",
    no_distribuidor: "Este negocio no es distribuidor de Quetzalitos. Pide que te activen la opción.",
    config_invalida: "Revisa los datos de tu tarjeta: meta de 1 a 50, color como #1F5BD6, logo con https o ruta img/negocios/.",
    tema_invalido: "Revisa el diseño: colores como #1F5BD6, emojis de hasta 8 caracteres e imagen con https.",
    token_cancelado: "Esta venta fue cancelada. Pide un QR nuevo en caja.",
    red: "Sin conexión. Revisa tu internet e intenta de nuevo."
  };
  // Raíz del sitio = carpeta de lib.js; así las rutas de logo valen desde cualquier página.
  var RAIZ = document.currentScript.src;
  // Tema: fuentes locales o del sistema (sin descargas externas) y mezcla de un color con blanco (255) o negro (0).
  var FUENTES = {
    "instrument-serif": '"Instrument Serif", "Iowan Old Style", Palatino, Georgia, serif',
    "dm-sans": '"DM Sans", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
    sistema: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
    georgia: 'Georgia, "Times New Roman", serif',
    redondeada: 'ui-rounded, "SF Pro Rounded", "Hiragino Maru Gothic ProN", Quicksand, system-ui, sans-serif',
    mono: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace'
  };
  var FUENTES_NOMBRES = [
    ["instrument-serif", "Elegante (Instrument Serif)"], ["dm-sans", "Moderna (DM Sans)"], ["sistema", "Del sistema"],
    ["georgia", "Clásica (Georgia)"], ["redondeada", "Redondeada"], ["mono", "Monoespaciada"]
  ];
  var TEMA_VARS = ["--rosa", "--rosa-osc", "--rosa-neon", "--rosa-claro", "--azul", "--azul-osc", "--azul-med", "--azul-neon",
    "--azul-claro", "--selva", "--selva-2", "--noche", "--serif", "--sans", "--fondo-img"];
  function mezcla(hex, hacia, p) {
    var h = "#";
    for (var i = 1; i < 7; i += 2) {
      var v = parseInt(hex.substr(i, 2), 16);
      h += (Math.round(v + (hacia - v) * p) + 256).toString(16).slice(1);
    }
    return h;
  }
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

    // URL absoluta del logo de un negocio; sin logo, el de Quetzalitos.
    logo: function (ruta) {
      return new URL(ruta || "img/logo.png", RAIZ).href;
    },

    // Aplica el tema visual de un negocio (objeto de entrar().tema; null = el de siempre) sobreponiendo variables CSS de :root.
    // Lo que no sea válido se ignora: el servidor ya valida, pero esto nunca pone texto sin comprobar en el CSS.
    tema: function (t) {
      var raiz = document.documentElement.style;
      TEMA_VARS.forEach(function (v) { raiz.removeProperty(v); });
      t = t || {};
      var hex = function (c) { return /^#[0-9a-fA-F]{6}$/.test(c || ""); };
      if (hex(t.acento)) {
        raiz.setProperty("--rosa", t.acento);
        raiz.setProperty("--rosa-osc", mezcla(t.acento, 0, .25));
        raiz.setProperty("--rosa-neon", mezcla(t.acento, 255, .25));
        raiz.setProperty("--rosa-claro", mezcla(t.acento, 255, .6));
      }
      if (hex(t.acento2)) {
        raiz.setProperty("--azul", t.acento2);
        raiz.setProperty("--azul-osc", mezcla(t.acento2, 0, .3));
        raiz.setProperty("--azul-med", mezcla(t.acento2, 255, .1));
        raiz.setProperty("--azul-neon", mezcla(t.acento2, 255, .3));
        raiz.setProperty("--azul-claro", mezcla(t.acento2, 255, .65));
      }
      if (hex(t.fondo)) {
        raiz.setProperty("--selva", t.fondo);
        raiz.setProperty("--selva-2", mezcla(t.fondo, 255, .08));
        raiz.setProperty("--noche", mezcla(t.fondo, 0, .55));
      }
      if (Object.prototype.hasOwnProperty.call(FUENTES, t.fuente_titulo)) raiz.setProperty("--serif", FUENTES[t.fuente_titulo]);
      if (Object.prototype.hasOwnProperty.call(FUENTES, t.fuente_texto)) raiz.setProperty("--sans", FUENTES[t.fuente_texto]);
      var fi = t.fondo_img || "";
      if (/^(https:\/\/[^\s"'<>()\\]+|img\/negocios\/[A-Za-z0-9._\/-]+|data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+\/]+=*)$/.test(fi)) {
        raiz.setProperty("--fondo-img", 'url("' + (fi.indexOf("data:") === 0 ? fi : new URL(fi, RAIZ).href) + '")');
      }
    },

    // «Bar · ESCA», o solo «Bar» cuando el negocio no tiene escuela (es opcional).
    subtitulo: function (tipo, escuela) {
      var partes = [];
      if (tipo) partes.push(tipo);
      if (escuela) partes.push(escuela);
      return partes.join(" · ");
    },

    // Fuentes disponibles para el tema (clave → nombre), en el orden del selector.
    fuentes: FUENTES_NOMBRES,

    msg: function (codigo) {
      return Object.prototype.hasOwnProperty.call(MENSAJES, codigo) ? MENSAJES[codigo] : GENERICO;
    }
  };
})();
