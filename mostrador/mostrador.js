// Mostrador: dibuja el QR de la caja y conecta el botón Imprimir.
(function () {
  var url = new URL("../caja/", location.href).href;
  var qrEl = document.getElementById("qr-caja");
  try {
    var qr = qrcode(0, "M");
    qr.addData(url);
    qr.make();
    qrEl.innerHTML = qr.createSvgTag({ cellSize: 6, margin: 4, scalable: true });
  } catch (e) {
    qrEl.textContent = "No se pudo generar el QR. Escribe la dirección de abajo.";
  }
  document.getElementById("url-caja").textContent = url;
  document.getElementById("btn-imprimir").addEventListener("click", function () {
    window.print();
  });
})();
