// Convierte docs/informe.html en PDF con Chromium (Playwright), con numeración de páginas.
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('file://' + path.resolve(__dirname, 'informe.html'), { waitUntil: 'networkidle' });
  await page.pdf({
    path: path.resolve(__dirname, 'Informe_Deber2_Smart_Inventory.pdf'),
    format: 'A4', printBackground: true, preferCSSPageSize: true,
    displayHeaderFooter: true,
    headerTemplate: '<div style="width:100%;font-size:7pt;color:#8a94a3;font-family:DejaVu Sans,Arial;padding:0 17mm;text-align:right">Smart Inventory · Deber 2 de Bases de Datos</div>',
    footerTemplate: '<div style="width:100%;font-size:7pt;color:#8a94a3;font-family:DejaVu Sans,Arial;padding:0 17mm;text-align:right"><span class="pageNumber"></span> / <span class="totalPages"></span></div>',
    margin: { top: '20mm', bottom: '20mm', left: '17mm', right: '17mm' },
  });
  await browser.close();
  console.log('PDF generado');
})();
