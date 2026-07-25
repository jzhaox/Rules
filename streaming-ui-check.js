/**
 * Quantumult X 流媒体解锁检测
 * Netflix / Disney+ / YouTube Premium / Paramount+ / HBO Max / Reddit / ChatGPT
 *
 * [task_local]
 * event-interaction https://raw.githubusercontent.com/YOUR_REPO/streaming-ui-check.js, tag=Check Media, img-url=play.tv.fill.system, enabled=true
 */

const UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const POLICY = $environment.params;
const REQUEST_TIMEOUT = 8000;

const OPENAI_SUPPORTED_REGIONS = new Set([
  "AL", "DZ", "AD", "AO", "AG", "AR", "AM", "AU", "AT", "AZ", "BS", "BD", "BB",
  "BE", "BZ", "BJ", "BT", "BA", "BW", "BR", "BG", "BF", "CV", "CA", "CL", "CO",
  "KM", "CR", "HR", "CY", "CZ", "DK", "DJ", "DM", "DO", "EC", "SV", "EE", "FJ",
  "FI", "FR", "GA", "GM", "GE", "DE", "GH", "GR", "GD", "GT", "GN", "GW", "GY",
  "HT", "HN", "HU", "IS", "IN", "ID", "IQ", "IE", "IL", "IT", "JM", "JP", "JO",
  "KZ", "KE", "KI", "KW", "KG", "LV", "LB", "LS", "LR", "LI", "LT", "LU", "MG",
  "MW", "MY", "MV", "ML", "MT", "MH", "MR", "MU", "MX", "MC", "MN", "ME", "MA",
  "MZ", "MM", "NA", "NR", "NP", "NL", "NZ", "NI", "NE", "NG", "MK", "NO", "OM",
  "PK", "PW", "PA", "PG", "PE", "PH", "PL", "PT", "QA", "RO", "RW", "KN", "LC",
  "VC", "WS", "SM", "ST", "SN", "RS", "SC", "SL", "SG", "SK", "SI", "SB", "ZA",
  "ES", "LK", "SR", "SE", "CH", "TH", "TG", "TO", "TT", "TN", "TR", "TV", "UG",
  "AE", "GB", "US", "UY", "VU", "ZM", "BO", "BN", "CG", "VA", "FM", "MD", "PS",
  "KR", "TW", "TZ", "TL", "T1", "XX"
]);

const SERVICES = [
  { key: "Netflix", icon: "N", color: "#e50914", test: testNetflix },
  { key: "Disney+", icon: "D+", color: "#4776e6", test: testDisney },
  { key: "YouTube Premium", icon: "▶", color: "#ff0033", test: testYouTube },
  { key: "Paramount+", icon: "P+", color: "#1261d8", test: testParamount },
  { key: "HBO Max", icon: "M", color: "#7b2cff", test: testHBOMax },
  { key: "Reddit", icon: "r/", color: "#ff4500", test: testReddit },
  { key: "ChatGPT", icon: "AI", color: "#10a37f", test: testChatGPT }
];

function request(options, timeout = REQUEST_TIMEOUT) {
  const task = Object.assign(
    {
      method: "GET",
      timeout,
      opts: { policy: POLICY },
      headers: { "User-Agent": UA, "Accept-Language": "en-US,en;q=0.9" }
    },
    options
  );
  task.opts = Object.assign({ policy: POLICY }, options.opts || {});
  task.headers = Object.assign(
    { "User-Agent": UA, "Accept-Language": "en-US,en;q=0.9" },
    options.headers || {}
  );

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), timeout);
    $task.fetch(task).then(
      response => {
        clearTimeout(timer);
        resolve(response);
      },
      error => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

function available(region, detail = "完整支持") {
  return { ok: true, region: normalizeRegion(region), detail };
}

function unavailable() {
  return { ok: false, region: "", detail: "不支持" };
}

function normalizeRegion(region) {
  const value = String(region || "").trim().toUpperCase();
  return /^[A-Z]{2}$/.test(value) ? value : "";
}

function regionFlag(region) {
  const code = normalizeRegion(region);
  if (!code) return "";
  return String.fromCodePoint(
    ...code.split("").map(char => 127397 + char.charCodeAt(0))
  );
}

function statusCode(response) {
  return Number(response.statusCode || response.status || 0);
}

function header(response, name) {
  const headers = response.headers || {};
  const target = name.toLowerCase();
  const key = Object.keys(headers).find(item => item.toLowerCase() === target);
  return key ? String(headers[key]) : "";
}

function extractTraceRegion(body) {
  const match = String(body || "").match(/(?:^|\n)loc=([A-Z]{2})(?:\n|$)/);
  return match ? match[1] : "";
}

async function getExitRegion() {
  try {
    const response = await request({
      url: "https://www.cloudflare.com/cdn-cgi/trace"
    });
    return extractTraceRegion(response.body);
  } catch (_) {
    return "";
  }
}

async function testNetflix() {
  try {
    const response = await request({
      url: "https://www.netflix.com/title/81280792",
      opts: { policy: POLICY, redirection: false }
    });
    const code = statusCode(response);

    if (code === 404) return available("", "仅自制剧");
    if (code !== 200) return unavailable();

    const source =
      header(response, "X-Originating-URL") ||
      header(response, "Location") ||
      response.body ||
      "";
    const match = String(source).match(/netflix\.com\/(?:([a-z]{2})-)?(?:[a-z]{2}\/)?title/i);
    return available(match && match[1] ? match[1] : "US");
  } catch (_) {
    return unavailable();
  }
}

async function testDisney() {
  try {
    const response = await request({
      url: "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql",
      method: "POST",
      headers: {
        Authorization:
          "ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        query:
          "mutation registerDevice($input: RegisterDeviceInput!) { registerDevice(registerDevice: $input) { grant { grantType assertion } } }",
        variables: {
          input: {
            applicationRuntime: "chrome",
            attributes: {
              browserName: "chrome",
              browserVersion: "125.0",
              manufacturer: "apple",
              model: null,
              operatingSystem: "macintosh",
              operatingSystemVersion: "14.5",
              osDeviceIds: []
            },
            deviceFamily: "browser",
            deviceLanguage: "en",
            deviceProfile: "macosx"
          }
        }
      })
    });

    if (statusCode(response) !== 200) return unavailable();
    const data = JSON.parse(response.body || "{}");
    const sdk = data && data.extensions && data.extensions.sdk;
    const session = sdk && sdk.session;
    const region = session && session.location && session.location.countryCode;
    const supported = session && session.inSupportedLocation;

    if (supported === false || supported === "false") return unavailable();
    return region ? available(region) : unavailable();
  } catch (_) {
    return unavailable();
  }
}

async function testYouTube() {
  try {
    const response = await request({
      url: "https://www.youtube.com/premium"
    });
    const body = String(response.body || "");
    if (
      statusCode(response) !== 200 ||
      /Premium is not available in your country/i.test(body)
    ) {
      return unavailable();
    }

    const match =
      body.match(/"GL"\s*:\s*"([A-Z]{2})"/) ||
      body.match(/"countryCode"\s*:\s*"([A-Z]{2})"/);
    const region = match ? match[1] : await getExitRegion();
    return available(region, "支持");
  } catch (_) {
    return unavailable();
  }
}

async function testParamount() {
  try {
    const response = await request({
      url: "https://www.paramountplus.com/",
      opts: { policy: POLICY, redirection: false }
    });
    if (statusCode(response) !== 200) return unavailable();
    return available(await getExitRegion(), "支持");
  } catch (_) {
    return unavailable();
  }
}

async function testHBOMax() {
  try {
    const [response, exitRegion] = await Promise.all([
      request({ url: "https://www.max.com/" }, 10000),
      getExitRegion()
    ]);
    if (statusCode(response) !== 200) return unavailable();

    const text = [
      response.body || "",
      header(response, "Location"),
      header(response, "X-Originating-URL")
    ].join("\n");
    const region =
      (text.match(/countryCode(?:=|%3D|["']?\s*:\s*["'])([A-Z]{2})/i) || [])[1] ||
      (text.match(/max\.com\/([a-z]{2})\/(?:en|[a-z]{2})(?:\/|$)/i) || [])[1] ||
      exitRegion;
    const code = normalizeRegion(region);
    if (!code) return unavailable();

    const localePattern = new RegExp(
      `(?:["']/|max\\.com/)${code.toLowerCase()}/[a-z]{2}(?:["'/]|$)`,
      "i"
    );
    const explicitlyBlocked =
      /not available in your (?:country|region)|unavailable-location/i.test(text);

    if (explicitlyBlocked) return unavailable();
    if (code === "US" || localePattern.test(text) || text.includes(`countryCode=${code}`)) {
      return available(code, "支持");
    }
    return unavailable();
  } catch (_) {
    return unavailable();
  }
}

async function testReddit() {
  try {
    const response = await request({
      url: "https://www.reddit.com/",
      opts: { policy: POLICY, redirection: true }
    });
    return statusCode(response) === 200
      ? available(await getExitRegion(), "可访问")
      : unavailable();
  } catch (_) {
    return unavailable();
  }
}

async function testChatGPT() {
  try {
    const [main, trace] = await Promise.all([
      request({
        url: "https://chatgpt.com/",
        opts: { policy: POLICY, redirection: false }
      }),
      request({ url: "https://chatgpt.com/cdn-cgi/trace" })
    ]);
    const code = statusCode(main);
    const region = extractTraceRegion(trace.body);
    const blocked =
      code === 403 ||
      /unsupported_country|not available in your country/i.test(
        String(main.body || "")
      );

    if (blocked || !region || !OPENAI_SUPPORTED_REGIONS.has(region)) {
      return unavailable();
    }
    return available(region, "支持");
  } catch (_) {
    return unavailable();
  }
}

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function renderCard(service, result) {
  const region = result.region
    ? `<span class="region">${regionFlag(result.region)} ${escapeHtml(result.region)}</span>`
    : "";
  return `
    <div class="card">
      <div class="brand" style="background:${service.color}">${service.icon}</div>
      <div class="info">
        <div class="name">${service.key}</div>
        <div class="detail">${escapeHtml(result.detail)} ${region}</div>
      </div>
      <div class="state ${result.ok ? "yes" : "no"}">${result.ok ? "✓" : "×"}</div>
    </div>`;
}

function renderHtml(results, nodeName) {
  const supported = results.filter(item => item.result.ok).length;
  const cards = results.map(item => renderCard(item.service, item.result)).join("");

  return `<!doctype html>
  <html>
  <head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      *{box-sizing:border-box}
      body{margin:0;padding:18px;background:linear-gradient(145deg,#eef2ff,#f8fafc 48%,#ecfeff);
        color:#172033;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif}
      .wrap{max-width:620px;margin:auto}
      .hero{padding:20px;border-radius:22px;background:linear-gradient(135deg,#111827,#243b78);
        color:white;box-shadow:0 12px 28px rgba(30,58,138,.20)}
      .hero-top{display:flex;align-items:center;justify-content:space-between}
      .title{font-size:22px;font-weight:750;letter-spacing:.2px}
      .score{padding:6px 10px;border-radius:999px;background:rgba(255,255,255,.14);
        font-size:13px;font-weight:650}
      .node{margin-top:10px;color:#dbeafe;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .grid{display:grid;grid-template-columns:1fr;gap:10px;margin-top:14px}
      .card{display:flex;align-items:center;min-height:68px;padding:12px 14px;background:rgba(255,255,255,.94);
        border:1px solid rgba(148,163,184,.20);border-radius:18px;box-shadow:0 6px 18px rgba(15,23,42,.06)}
      .brand{width:42px;height:42px;border-radius:13px;color:white;display:flex;align-items:center;
        justify-content:center;font-size:15px;font-weight:800;box-shadow:inset 0 0 0 1px rgba(255,255,255,.18)}
      .info{flex:1;min-width:0;margin-left:12px}
      .name{font-size:16px;font-weight:720}
      .detail{margin-top:4px;color:#64748b;font-size:13px}
      .region{margin-left:5px;color:#334155;font-weight:650}
      .state{width:30px;height:30px;border-radius:50%;display:flex;align-items:center;justify-content:center;
        color:white;font-size:18px;font-weight:800}
      .yes{background:#22c55e;box-shadow:0 5px 12px rgba(34,197,94,.24)}
      .no{background:#ef4444;box-shadow:0 5px 12px rgba(239,68,68,.20)}
      .foot{text-align:center;margin:14px 0 2px;color:#94a3b8;font-size:11px}
      @media(min-width:540px){.grid{grid-template-columns:1fr 1fr}}
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="hero">
        <div class="hero-top">
          <div class="title">📺 媒体解锁检测</div>
          <div class="score">${supported} / ${results.length} 可用</div>
        </div>
        <div class="node">当前节点 · ${escapeHtml(nodeName || "未命名策略")}</div>
      </div>
      <div class="grid">${cards}</div>
      <div class="foot">Quantumult X · Streaming Access</div>
    </div>
  </body>
  </html>`;
}

async function getPolicyName() {
  try {
    const message = { action: "get_policy_state", content: POLICY };
    const response = await $configuration.sendMessage(message);
    const value = response && response.ret && response.ret[POLICY];
    if (Array.isArray(value)) return value.join("  →  ");
    return value ? String(value) : POLICY;
  } catch (_) {
    return POLICY;
  }
}

(async () => {
  const rawResults = await Promise.all(
    SERVICES.map(service =>
      Promise.resolve()
        .then(() => service.test())
        .catch(() => unavailable())
    )
  );
  const results = SERVICES.map((service, index) => ({
    service,
    result: rawResults[index] || unavailable()
  }));
  const nodeName = await getPolicyName();
  $done({
    title: "媒体解锁检测",
    htmlMessage: renderHtml(results, nodeName)
  });
})().catch(error => {
  console.log(`Media check error: ${error}`);
  const results = SERVICES.map(service => ({ service, result: unavailable() }));
  $done({
    title: "媒体解锁检测",
    htmlMessage: renderHtml(results, POLICY)
  });
});
