// Renders every *.html in this folder to ../<name>.png (2x). Usage: node render.js
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ deviceScaleFactor: 2, viewport: { width: 1300, height: 900 } });
  for (const f of fs.readdirSync(__dirname).filter(f => f.endsWith('.html'))) {
    await p.goto('file://' + path.join(__dirname, f));
    await p.locator('#d').screenshot({ path: path.join(__dirname, '..', f.replace('.html', '.png')) });
    console.log('rendered', f);
  }
  await b.close();
})();
