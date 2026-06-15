# Transport Encryption Implementation Example

The security audit identified a missing transport encryption vulnerability. The fix is to ensure every client and service endpoint communicates over TLS, rejects plaintext HTTP, and uses a modern TLS configuration.

## Example: Node.js HTTPS service with HTTP-to-HTTPS redirect

```js
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import express from "express";

const app = express();

// Enforce HSTS so browsers only use HTTPS for this host after the first secure response.
app.use((req, res, next) => {
  res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  next();
});

app.get("/health", (_req, res) => {
  res.status(200).json({ ok: true });
});

const tlsOptions = {
  key: fs.readFileSync(process.env.TLS_KEY_PATH),
  cert: fs.readFileSync(process.env.TLS_CERT_PATH),
  minVersion: "TLSv1.2",
  honorCipherOrder: true,
};

https.createServer(tlsOptions, app).listen(443, () => {
  console.log("HTTPS service listening on port 443");
});

http
  .createServer((req, res) => {
    const host = req.headers.host?.replace(/:\d+$/, "") ?? "localhost";
    res.writeHead(308, { Location: `https://${host}${req.url}` });
    res.end();
  })
  .listen(80, () => {
    console.log("HTTP redirect service listening on port 80");
  });
```

## Example: secure outbound API client

```js
import https from "node:https";

const agent = new https.Agent({
  minVersion: "TLSv1.2",
  rejectUnauthorized: true,
});

const response = await fetch("https://api.example.com/v1/resource", {
  agent,
  headers: {
    Authorization: `Bearer ${process.env.API_TOKEN}`,
  },
});

if (!response.ok) {
  throw new Error(`API request failed with status ${response.status}`);
}
```

## Implementation checklist

- Replace all plaintext `http://` service URLs with `https://` endpoints.
- Install certificates from a trusted certificate authority or an internal private CA.
- Configure servers with `minVersion: "TLSv1.2"` or newer.
- Enable HSTS for browser-facing applications.
- Keep `rejectUnauthorized: true` for clients so invalid or self-signed certificates are not silently accepted.
- Redirect port 80 traffic to HTTPS, but do not serve sensitive responses over HTTP.
- Add automated tests or deployment policy checks that fail when plaintext endpoints are introduced.
