#!/bin/bash

echo ""
echo "🛠️ Generating Dockerfile..."
cat << 'EOF' > Dockerfile
FROM node:20

RUN apt-get update && apt-get install -y \
  wget ca-certificates \
  fonts-liberation libappindicator3-1 libasound2 \
  libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
  libgbm1 libgtk-3-0 libnspr4 libnss3 libx11-xcb1 \
  libxcomposite1 libxdamage1 libxrandr2 xdg-utils \
  --no-install-recommends && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN npm install

CMD ["node", "index.js"]
EOF

echo ""
echo "📦 Creating package.json..."
cat << 'EOF' > package.json
{
  "name": "tesla-service-scraper",
  "version": "1.0.0",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "puppeteer": "^22.8.2"
  }
}
EOF

echo ""
echo "📜 Creating index.js (Puppeteer script)..."
cat << 'EOF' > index.js
const puppeteer = require("puppeteer");
const wait = ms => new Promise(res => setTimeout(res, ms));

(async () => {
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
    defaultViewport: { width: 1600, height: 1200 },
  });

  const page = await browser.newPage();

  console.log("🔗 Navigating to Tesla Service Manual...");
  await page.goto("https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/index.html", {
    waitUntil: "networkidle2",
    timeout: 60000,
  });

  // Retry loop for loading sidebar
  let sidebarLinks = [];
  for (let attempt = 1; attempt <= 5; attempt++) {
    console.log(`⏳ Waiting for sidebar (attempt ${attempt}/5)...`);
    await wait(10000);
    try {
      sidebarLinks = await page.$$eval('aside .tds-list a', (links) =>
        links.map(link => ({
          href: link.href,
          title: link.textContent.trim()
        }))
      );
      console.log(`🔍 Found ${sidebarLinks.length} sidebar links`);
      if (sidebarLinks.length > 0) break;
    } catch (err) {
      console.warn(`⚠️ Sidebar query failed: ${err.message}`);
    }
    console.warn("⚠️ Sidebar still not populated, retrying...");
  }

  if (sidebarLinks.length === 0) {
    console.error("❌ Failed to load sidebar links after 5 attempts. Exiting.");
    await browser.close();
    process.exit(1);
  }

  const collectedHTML = [];
  console.log(`📚 Found ${sidebarLinks.length} sections.`);

  for (let i = 0; i < sidebarLinks.length; i++) {
    const { href, title } = sidebarLinks[i];
    console.log(`➡️  [${i + 1}/${sidebarLinks.length}] ${title}`);

    await page.goto(href, { waitUntil: "networkidle2", timeout: 60000 });

    try {
      await page.waitForSelector("main", { timeout: 10000 });

      await page.evaluate(() => {
        document.querySelectorAll("button.section-header").forEach(btn => {
          if (btn.getAttribute("aria-expanded") === "false") btn.click();
        });
      });

      await wait(1000);

      const html = await page.$eval("main", (main) => main.innerHTML);
      collectedHTML.push(`<section style="page-break-after: always;">
        <h1 style="font-size:24px; border-bottom:1px solid #ccc; margin-top:40px;">${title}</h1>
        ${html}
      </section>`);
    } catch (err) {
      console.warn(`⚠️ Skipped: ${title}`);
    }
  }

  console.log("🛠️ Assembling final PDF...");
  const printPage = await browser.newPage();
  await printPage.setContent(`
    <html>
      <head>
        <style>
          @page { size: 11in 17in landscape; margin: 0.5in; }
          body { font-family: sans-serif; padding: 20px; }
          section { page-break-after: always; margin-bottom: 40px; }
        </style>
      </head>
      <body>
        ${collectedHTML.join("\n")}
      </body>
    </html>
  `, { waitUntil: "networkidle0" });

  await printPage.pdf({
    path: "/data/tesla-model-x-service-manual.pdf",
    format: "tabloid",
    landscape: true,
    printBackground: true,
    margin: { top: "0.5in", bottom: "0.5in", left: "0.5in", right: "0.5in" },
  });

  await browser.close();
  console.log("✅ Done! PDF saved to /data/tesla-model-x-service-manual.pdf");
})();
EOF

echo ""
echo "📦 Building container image..."
podman build -t tesla-pdf .

echo ""
echo "🚀 Running Puppeteer script inside container..."
podman run --rm -v "$PWD:/data:z" tesla-pdf

echo ""
echo "✅ All done. Check tesla-model-x-service-manual.pdf in your folder."
