// Copiar este bloque en Codigo.gs de BomanSport y publicar una nueva version
// del Web App. Usa el mismo API_TOKEN de la sincronizacion actual.
function doPost(e) {
  var json = function(obj) {
    return ContentService.createTextOutput(JSON.stringify(obj))
      .setMimeType(ContentService.MimeType.JSON);
  };
  try {
    if (!e || !e.parameter || e.parameter.api !== 'respaldo-contrato') {
      return json({ ok: false, error: 'Ruta POST no reconocida' });
    }
    var esperado = PropertiesService.getScriptProperties().getProperty('API_TOKEN');
    if (!esperado || String(e.parameter.token || '').trim() !== String(esperado).trim()) {
      return json({ ok: false, error: 'No autorizado' });
    }
    var datos = JSON.parse(e.postData && e.postData.contents || '{}');
    var c = datos.contrato || {};
    var id = String(c.id || '').trim(), numero = String(c.numero || '').trim();
    if (!id || !/^BOM-[0-9]{4}-[0-9]{4,}$/.test(numero)) {
      return json({ ok: false, error: 'Contrato de respaldo invalido' });
    }
    var lock = LockService.getScriptLock();
    lock.waitLock(20000);
    try {
      var carpetas = DriveApp.getFoldersByName('Boman Respaldos Vercel');
      var carpeta = carpetas.hasNext() ? carpetas.next() : DriveApp.createFolder('Boman Respaldos Vercel');
      var nombre = numero + '_' + id + '.json';
      var archivos = carpeta.getFilesByName(nombre);
      var contenido = JSON.stringify(datos, null, 2);
      var archivo;
      if (archivos.hasNext()) { archivo = archivos.next(); archivo.setContent(contenido); }
      else archivo = carpeta.createFile(nombre, contenido, MimeType.PLAIN_TEXT);

      var ss = SpreadsheetApp.getActiveSpreadsheet();
      var hoja = ss.getSheetByName('Respaldo Vercel') || ss.insertSheet('Respaldo Vercel');
      if (hoja.getLastRow() === 0) hoja.appendRow(['Numero','ID Supabase','Respaldado','Cliente','Vendedor','Entrega','Prendas','Presupuesto','Archivo Drive']);
      var fila = 0;
      if (hoja.getLastRow() > 1) {
        var ids = hoja.getRange(2, 2, hoja.getLastRow() - 1, 1).getDisplayValues();
        for (var i = 0; i < ids.length; i++) if (String(ids[i][0]).trim() === id) { fila = i + 2; break; }
      }
      var valores = [[numero,id,new Date(),c.cliente || '',c.vendedor || '',c.fecha_entrega || '',Number(c.total_prendas || 0),Number(c.presupuesto || 0),archivo.getUrl()]];
      hoja.getRange(fila || hoja.getLastRow() + 1, 1, 1, valores[0].length).setValues(valores);
      return json({ ok: true, numero: numero, url: archivo.getUrl() });
    } finally { lock.releaseLock(); }
  } catch (err) {
    Logger.log('Respaldo Vercel fallo: ' + (err.stack || err.message || err));
    return json({ ok: false, error: String(err.message || err) });
  }
}
