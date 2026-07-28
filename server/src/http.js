/// Accepts `/v1/polish` and, when a base path is configured, `<base>/v1/polish` too,
/// so the relay works whether or not the reverse proxy in front of it strips the
/// prefix. Depending on the proxy having exactly the right trailing slash is a
/// deployment trap: getting it wrong surfaces as a bare 404 with nothing in the logs.
export function routePath(url, basePath) {
  if (basePath && (url.pathname === basePath
      || url.pathname.startsWith(`${basePath}/`))) {
    return url.pathname.slice(basePath.length) || "/";
  }
  return url.pathname;
}

export function writeJSON(response, statusCode, object, extraHeaders = {}) {
  const body = Buffer.from(JSON.stringify(object));
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": body.length,
    "cache-control": "no-store",
    ...extraHeaders,
  });
  response.end(body);
}

export function errorBody(message, code = "relay_error") {
  return { error: { message, type: "relay_error", code } };
}

export async function readBody(request, limitBytes) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > limitBytes) {
      request.resume();
      const error = new Error("request body too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total);
}
