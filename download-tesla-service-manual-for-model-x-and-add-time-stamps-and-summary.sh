#!/bin/bash
###################################################################################################################
#
#  Build a PDF of the Tesla Model X 2022 Service Manual 
#     https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/index.html
#
#  Using a specialized container and the index.html
#
#
####################################################################################################################
set -euo pipefail

echo ""
echo "🛠️ Generating Dockerfile..."
cat > Dockerfile <<'EOF'
FROM node:20-bookworm

RUN apt-get update && apt-get install -y \
    ca-certificates \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libu2f-udev \
    libvulkan1 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    wget \
    xdg-utils \
    --no-install-recommends && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY index.js ./

CMD ["node", "index.js"]
EOF

echo ""
echo "📦 Creating package.json..."
cat > package.json <<'EOF'
{
  "name": "tesla-service-manual-pdf",
  "version": "3.1.0",
  "private": true,
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "puppeteer": "^24.0.0"
  }
}
EOF

echo ""
echo "📜 Creating index.js..."
cat > index.js <<'EOF'
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer");

const START_URL =
  "https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/index.html";

const BASE_URL =
  "https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/";

const OUT_DIR = "/data/tesla-model-x-service-manual-assets";
const PDF_PATH = "/data/tesla-model-x-service-manual.pdf";
const HTML_PATH = "/data/tesla-model-x-service-manual-combined.html";
const RUN_LOG_PATH = "/data/tesla-model-x-service-manual-run-summary.json";

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function fmtSeconds(ms) {
  return `${(ms / 1000).toFixed(1)}s`;
}

function fmtDuration(ms) {
  const totalSeconds = Math.round(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;

  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

function calcEta(startTime, completed, total) {
  if (completed <= 0) return "calculating";
  const elapsed = Date.now() - startTime;
  const avg = elapsed / completed;
  const remaining = total - completed;
  return fmtDuration(avg * remaining);
}

async function autoScroll(page) {
  await page.evaluate(async () => {
    await new Promise(resolve => {
      let lastHeight = 0;
      let sameCount = 0;

      const timer = setInterval(() => {
        window.scrollBy(0, 900);
        const height = document.body.scrollHeight;

        if (height === lastHeight) {
          sameCount++;
        } else {
          sameCount = 0;
          lastHeight = height;
        }

        if (sameCount >= 4) {
          clearInterval(timer);
          resolve();
        }
      }, 200);
    });
  });
}

async function gotoWithRetry(page, url, attempts = 3) {
  let lastError;

  for (let i = 1; i <= attempts; i++) {
    try {
      await page.goto(url, {
        waitUntil: "networkidle2",
        timeout: 90000
      });
      return;
    } catch (err) {
      lastError = err;
      console.warn(`⚠️  Load failed attempt ${i}/${attempts}: ${url}`);
      await wait(2500);
    }
  }

  throw lastError;
}

async function collectAssetUrls(page) {
  return page.evaluate(() => {
    const urls = new Set();

    const add = value => {
      if (!value) return;
      try {
        urls.add(new URL(value, location.href).href);
      } catch {}
    };

    document.querySelectorAll("img[src]").forEach(el => add(el.getAttribute("src")));
    document.querySelectorAll("link[href]").forEach(el => add(el.getAttribute("href")));
    document.querySelectorAll("script[src]").forEach(el => add(el.getAttribute("src")));
    document.querySelectorAll("source[src]").forEach(el => add(el.getAttribute("src")));

    document.querySelectorAll("[srcset]").forEach(el => {
      const srcset = el.getAttribute("srcset") || "";
      srcset.split(",").forEach(part => {
        const url = part.trim().split(/\s+/)[0];
        add(url);
      });
    });

    document.querySelectorAll("use[href], use[xlink\\:href]").forEach(el => {
      const href = el.getAttribute("href") || el.getAttribute("xlink:href");
      if (href && !href.startsWith("#")) {
        add(href.split("#")[0]);
      }
    });

    return Array.from(urls);
  });
}

(async () => {
  const runStarted = Date.now();

  fs.mkdirSync(OUT_DIR, { recursive: true });

  const browser = await puppeteer.launch({
    headless: "new",
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage"
    ],
    defaultViewport: {
      width: 1700,
      height: 1200
    }
  });

  const page = await browser.newPage();
  page.setDefaultTimeout(30000);

  const runStats = {
    startedAt: new Date(runStarted).toISOString(),
    completedAt: null,
    pagesDiscovered: 0,
    pagesDownloaded: 0,
    pagesSkipped: 0,
    totalImages: 0,
    totalTables: 0,
    totalLinks: 0,
    totalFigures: 0,
    totalAssets: 0,
    pageTimings: [],
    skippedPages: []
  };

  console.log("🔗 Opening Tesla service manual index...");
  await gotoWithRetry(page, START_URL);

  await page.waitForSelector("aside .side-nav a[href], main", {
    timeout: 30000
  });

  console.log("📚 Reading sidebar links...");

  const links = await page.$$eval("aside .side-nav a[href]", anchors => {
    const seen = new Set();

    return anchors
      .map(a => {
        const href = new URL(a.getAttribute("href"), location.href).href;
        const title = a.textContent.replace(/\s+/g, " ").trim();
        return { href, title };
      })
      .filter(x =>
        x.href.startsWith(
          "https://service.tesla.com/docs/ModelX/ServiceManual/Palladium/en-us/"
        ) &&
        x.href.endsWith(".html") &&
        x.title
      )
      .filter(x => {
        if (seen.has(x.href)) return false;
        seen.add(x.href);
        return true;
      });
  });

  const pages = [
    {
      href: START_URL,
      title: "Model X Service Manual (2021+)"
    },
    ...links.filter(x => x.href !== START_URL)
  ];

  runStats.pagesDiscovered = pages.length;

  console.log(`✅ Found ${pages.length} pages.`);
  console.log("");

  const allAssetUrls = new Set();
  const collectedSections = [];

  for (let i = 0; i < pages.length; i++) {
    const pageStarted = Date.now();
    const { href, title } = pages[i];

    try {
      await gotoWithRetry(page, href);
      await page.waitForSelector("main", { timeout: 30000 });

      await autoScroll(page);

      await page.evaluate(() => {
        document.querySelectorAll("button[aria-expanded='false']").forEach(button => {
          try {
            button.click();
          } catch {}
        });

        document.querySelectorAll("details:not([open])").forEach(details => {
          details.setAttribute("open", "open");
        });
      });

      await wait(750);

      const pageStats = await page.evaluate(() => ({
        images: document.querySelectorAll("main img").length,
        tables: document.querySelectorAll("main table").length,
        links: document.querySelectorAll("main a").length,
        figures: document.querySelectorAll("main figure").length
      }));

      const assetUrls = await collectAssetUrls(page);
      assetUrls.forEach(url => allAssetUrls.add(url));

      const html = await page.$eval("main", main => {
        main.querySelectorAll("script, noscript, iframe").forEach(el => el.remove());

        main.querySelectorAll("a[href]").forEach(a => {
          try {
            a.href = new URL(a.getAttribute("href"), location.href).href;
          } catch {}
        });

        main.querySelectorAll("img[src]").forEach(img => {
          try {
            img.src = new URL(img.getAttribute("src"), location.href).href;
          } catch {}
        });

        main.querySelectorAll("source[src]").forEach(source => {
          try {
            source.src = new URL(source.getAttribute("src"), location.href).href;
          } catch {}
        });

        return main.innerHTML;
      });

      collectedSections.push(`
        <section class="manual-section" data-source="${escapeHtml(href)}">
          <h1 class="section-title">${escapeHtml(title)}</h1>
          <div class="source-link">Source: ${escapeHtml(href)}</div>
          ${html}
        </section>
      `);

      const durationMs = Date.now() - pageStarted;

      runStats.pagesDownloaded++;
      runStats.totalImages += pageStats.images;
      runStats.totalTables += pageStats.tables;
      runStats.totalLinks += pageStats.links;
      runStats.totalFigures += pageStats.figures;

      runStats.pageTimings.push({
        index: i + 1,
        title,
        href,
        status: "success",
        durationMs,
        images: pageStats.images,
        tables: pageStats.tables,
        links: pageStats.links,
        figures: pageStats.figures
      });

      const completed = i + 1;
      const pct = ((completed / pages.length) * 100).toFixed(1);
      const elapsed = fmtDuration(Date.now() - runStarted);
      const eta = calcEta(runStarted, completed, pages.length);

      console.log(
        `✓ [${completed}/${pages.length}] ${title} [${fmtSeconds(durationMs)}] ` +
        `img:${pageStats.images} tbl:${pageStats.tables} fig:${pageStats.figures} ` +
        `| ${pct}% | elapsed:${elapsed} | ETA:${eta}`
      );
    } catch (err) {
      const durationMs = Date.now() - pageStarted;

      runStats.pagesSkipped++;

      runStats.skippedPages.push({
        index: i + 1,
        title,
        href,
        error: err.message,
        durationMs
      });

      runStats.pageTimings.push({
        index: i + 1,
        title,
        href,
        status: "skipped",
        error: err.message,
        durationMs
      });

      collectedSections.push(`
        <section class="manual-section skipped">
          <h1 class="section-title">${escapeHtml(title)}</h1>
          <p>Skipped due to load error: ${escapeHtml(err.message)}</p>
          <p>${escapeHtml(href)}</p>
        </section>
      `);

      const completed = i + 1;
      const pct = ((completed / pages.length) * 100).toFixed(1);
      const elapsed = fmtDuration(Date.now() - runStarted);
      const eta = calcEta(runStarted, completed, pages.length);

      console.log(
        `✗ [${completed}/${pages.length}] ${title} FAILED [${fmtSeconds(durationMs)}] ` +
        `| ${pct}% | elapsed:${elapsed} | ETA:${eta}`
      );
    }
  }

  runStats.totalAssets = allAssetUrls.size;

  console.log("");
  console.log(`🖼️  Found ${allAssetUrls.size} referenced assets.`);

  fs.writeFileSync(
    path.join(OUT_DIR, "asset-urls.txt"),
    Array.from(allAssetUrls).sort().join("\n")
  );

  console.log("🛠️ Assembling combined HTML...");

  const combinedHtml = `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <base href="${BASE_URL}">
  <title>Tesla Model X Service Manual PDF</title>

  <link rel="stylesheet" href="${BASE_URL}css/custom.css">
  <link rel="stylesheet" href="https://digitalassets.tesla.com/tesla-design-system/raw/upload/design-system/9.0.1/index.css">

  <style>
    @page {
      size: 17in 11in;
      margin: 0.45in;
    }

    html,
    body {
      font-family: Arial, Helvetica, sans-serif;
      font-size: 11px;
      line-height: 1.35;
      color: #111;
      background: white;
    }

    .manual-section {
      break-after: page;
      page-break-after: always;
    }

    .section-title {
      font-size: 22px;
      border-bottom: 1px solid #999;
      padding-bottom: 8px;
      margin: 0 0 8px 0;
    }

    .source-link {
      font-size: 8px;
      color: #666;
      margin-bottom: 16px;
      word-break: break-all;
    }

    img,
    svg,
    video,
    canvas {
      max-width: 100%;
      height: auto;
    }

    table {
      border-collapse: collapse;
      width: 100%;
      page-break-inside: auto;
    }

    tr {
      page-break-inside: avoid;
      page-break-after: auto;
    }

    th,
    td {
      border: 1px solid #ccc;
      padding: 4px;
      vertical-align: top;
    }

    pre,
    code {
      white-space: pre-wrap;
      word-break: break-word;
    }

    a {
      color: #111;
      text-decoration: none;
    }

    .tds-shell-content,
    main,
    article {
      max-width: none !important;
      width: 100% !important;
    }

    .skipped {
      color: #900;
    }
  </style>
</head>
<body>
  ${collectedSections.join("\n")}
</body>
</html>
`;

  fs.writeFileSync(HTML_PATH, combinedHtml);

  console.log("🖨️ Rendering PDF...");

  const pdfStarted = Date.now();
  const printPage = await browser.newPage();

  printPage.setDefaultNavigationTimeout(0);
  printPage.setDefaultTimeout(0);

  await printPage.setContent(combinedHtml, {
    waitUntil: "domcontentloaded",
    timeout: 0
  });

  console.log("⏳ Waiting 10 seconds for images/styles to settle...");
  await wait(10000);

  await printPage.pdf({
    path: PDF_PATH,
    width: "17in",
    height: "11in",
    printBackground: true,
    preferCSSPageSize: true,
    timeout: 0,
    margin: {
      top: "0.45in",
      bottom: "0.45in",
      left: "0.45in",
      right: "0.45in"
    },
    displayHeaderFooter: true,
    headerTemplate: `<div></div>`,
    footerTemplate: `
      <div style="font-size:8px;width:100%;padding:0 0.45in;color:#666;">
        <span class="title"></span>
        <span style="float:right;">
          Page <span class="pageNumber"></span> of <span class="totalPages"></span>
        </span>
      </div>
    `
  });

  const pdfDurationMs = Date.now() - pdfStarted;

  await browser.close();

  runStats.completedAt = new Date().toISOString();
  runStats.pdfRenderDurationMs = pdfDurationMs;
  runStats.totalRuntimeMs = Date.now() - runStarted;

  const successfulTimings = runStats.pageTimings.filter(x => x.status === "success");

  const fastest = successfulTimings.reduce(
    (best, x) => (!best || x.durationMs < best.durationMs ? x : best),
    null
  );

  const slowest = successfulTimings.reduce(
    (best, x) => (!best || x.durationMs > best.durationMs ? x : best),
    null
  );

  const avgMs =
    successfulTimings.length > 0
      ? successfulTimings.reduce((sum, x) => sum + x.durationMs, 0) / successfulTimings.length
      : 0;

  fs.writeFileSync(RUN_LOG_PATH, JSON.stringify(runStats, null, 2));

  console.log("");
  console.log("=========================================================");
  console.log("Tesla Service Manual Crawl Summary");
  console.log("=========================================================");
  console.log(`Pages discovered : ${runStats.pagesDiscovered}`);
  console.log(`Pages downloaded : ${runStats.pagesDownloaded}`);
  console.log(`Pages skipped    : ${runStats.pagesSkipped}`);
  console.log("");
  console.log(`Images           : ${runStats.totalImages}`);
  console.log(`Tables           : ${runStats.totalTables}`);
  console.log(`Figures          : ${runStats.totalFigures}`);
  console.log(`Links            : ${runStats.totalLinks}`);
  console.log(`Assets found     : ${runStats.totalAssets}`);
  console.log("");
  console.log(`Average/page     : ${fmtSeconds(avgMs)}`);
  if (fastest) console.log(`Fastest page     : ${fmtSeconds(fastest.durationMs)} - ${fastest.title}`);
  if (slowest) console.log(`Slowest page     : ${fmtSeconds(slowest.durationMs)} - ${slowest.title}`);
  console.log("");
  console.log(`PDF render time  : ${fmtDuration(pdfDurationMs)}`);
  console.log(`Total runtime    : ${fmtDuration(runStats.totalRuntimeMs)}`);
  console.log("=========================================================");
  console.log("");
  console.log(`✅ PDF saved: ${PDF_PATH}`);
  console.log(`✅ Combined HTML saved: ${HTML_PATH}`);
  console.log(`✅ Asset URL list saved: ${path.join(OUT_DIR, "asset-urls.txt")}`);
  console.log(`✅ Run summary saved: ${RUN_LOG_PATH}`);
})();
EOF

echo ""
echo "📦 Building container image..."
podman build -t tesla-service-manual-pdf .

echo ""
echo "🚀 Running scraper..."
podman run --rm --shm-size=2g -v "$PWD:/data:z" tesla-service-manual-pdf 2>&1 | tee tesla-service-manual-run.log

echo ""
echo "✅ Done."
echo "Output files:"
echo "  tesla-model-x-service-manual.pdf"
echo "  tesla-model-x-service-manual-combined.html"
echo "  tesla-model-x-service-manual-assets/asset-urls.txt"
echo "  tesla-model-x-service-manual-run-summary.json"
echo "  tesla-service-manual-run.log"
