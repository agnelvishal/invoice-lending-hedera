// Node 20's default https agent applies a 5s socket timeout, which fails on high-latency links.
// Preload with: NODE_OPTIONS="--require /path/to/slow-network-patch.cjs"
const https = require("https");
const http = require("http");
https.globalAgent = new https.Agent({ keepAlive: true, timeout: 120000 });
http.globalAgent = new http.Agent({ keepAlive: true, timeout: 120000 });
