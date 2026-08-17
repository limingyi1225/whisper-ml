import { errorBody, readBody, writeJSON } from "./http.js";

const ALLOWED_BODY_KEYS = new Set(["model", "messages", "reasoning_effort"]);

/// Both values are live, and both have to stay live. The app moved from `none` to
/// `low` (measured: no latency cost, and it repairs misheard homophones `none`
/// leaves alone), but every already-installed copy keeps sending `none` until it
/// updates itself — narrowing this to one value would break cleanup on exactly the
/// versions that have not picked up the change yet. The set stays closed regardless:
/// `medium` and `high` are what turn a 1s cleanup into a wait the user feels, on a
/// key that is not theirs.
const ALLOWED_REASONING_EFFORT = new Set(["none", "low"]);

/// Chinese lead, English detail in parentheses — same reasoning as `REJECT` in
/// realtime.js: the app surfaces `error.message` verbatim as the cleanup notice.
/// `reasoning_effort` must stay spelled out in that message: the app probes for it in
/// a 400 body to decide whether to retry the request without the parameter.
const REJECT = Object.freeze({
  notObject: "转发服务器：请求体必须是 JSON 对象（JSON body must be an object）",
  bodyField:
    "转发服务器：整理请求含有不支持的字段"
    + "（request contains an unsupported field）",
  model: "转发服务器不允许这个模型（model is not allowed）",
  reasoning:
    "转发服务器不允许这个 reasoning_effort 取值"
    + "（reasoning_effort is not allowed）",
  messages:
    "转发服务器：messages 必须正好是 system 和 user 两条"
    + "（messages must contain exactly system and user entries）",
  system: "转发服务器：system 消息无效（invalid system message）",
  user: "转发服务器：user 消息无效（invalid user message）",
});

export function validatePolishBody(body, config) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return REJECT.notObject;
  }
  if (Object.keys(body).some((key) => !ALLOWED_BODY_KEYS.has(key))) {
    return REJECT.bodyField;
  }
  if (typeof body.model !== "string" || !config.allowedPolishModels.has(body.model)) {
    return REJECT.model;
  }
  if (body.reasoning_effort !== undefined
      && !ALLOWED_REASONING_EFFORT.has(body.reasoning_effort)) {
    return REJECT.reasoning;
  }
  if (!Array.isArray(body.messages) || body.messages.length !== 2) {
    return REJECT.messages;
  }

  const [system, user] = body.messages;
  if (system?.role !== "system" || typeof system.content !== "string"
      || system.content.length > 24_000) {
    return REJECT.system;
  }
  if (user?.role !== "user" || typeof user.content !== "string"
      || user.content.length > 64_000) {
    return REJECT.user;
  }
  return null;
}

export async function handlePolish(
  request,
  response,
  {
    config,
    deviceID,
    rateLimiter,
    fetchImpl = fetch,
    stillAuthorized = () => true,
    registerAbort = null,
    takeDailyQuota = () => null,
  },
) {
  if (!rateLimiter.take(deviceID)) {
    writeJSON(response, 429, errorBody("请求太频繁，请稍后再试", "relay_rate_limit"));
    return;
  }

  let raw;
  try {
    raw = await readBody(request, config.maxPolishBodyBytes);
  } catch (error) {
    writeJSON(
      response,
      error.statusCode || 400,
      errorBody("整理请求过大", "relay_body_too_large"),
    );
    return;
  }

  let body;
  try {
    body = JSON.parse(raw.toString("utf8"));
  } catch {
    writeJSON(response, 400, errorBody("整理请求不是有效 JSON", "relay_invalid_json"));
    return;
  }

  const validationError = validatePolishBody(body, config);
  if (validationError) {
    writeJSON(response, 400, errorBody(validationError, "relay_invalid_request"));
    return;
  }

  // The Bearer check ran when the headers arrived, but everything up to here waits on
  // the client — a deliberately slow body can hold this handler open across a
  // revocation. Re-checked at the last moment before the server's key is spent, so
  // "revoked" means revoked for in-flight requests too, not just future ones.
  if (!stillAuthorized()) {
    writeJSON(
      response,
      401,
      errorBody("转发服务器设备 Token 无效或没有权限", "relay_unauthorized"),
      { "www-authenticate": "Bearer" },
    );
    return;
  }

  const dailyQuota = takeDailyQuota();
  if (dailyQuota) {
    writeJSON(
      response,
      429,
      errorBody(
        dailyQuota === "total"
          ? "转发服务器今天的整理总额度已用完，请稍后再试"
          : "今天的整理额度已用完，请明天再试",
        "relay_daily_quota",
      ),
    );
    return;
  }

  // Re-serialized rather than forwarded verbatim, to force an output ceiling the
  // client cannot raise. Without it the only limit on a generation is the response-size
  // check further down — which runs after the tokens have been generated and billed, so
  // it bounds nothing that costs money. The cap is far above any real utterance (the
  // app's whole 610 s buffer transcribes to well under this), so a truncated reply means
  // something is wrong, and the app's plausibility guard falls back to the raw text.
  const forwardBody = JSON.stringify({
    ...body,
    max_completion_tokens: config.maxPolishCompletionTokens,
  });

  // The app cancels its cleanup request the moment the user starts the next sentence,
  // which in back-to-back dictation is most of them. Without following that
  // cancellation upstream, OpenAI keeps generating — and billing — for a reply nobody
  // will ever read, for up to the full request timeout.
  const abandoned = new AbortController();
  const abandon = () => {
    if (!response.writableEnded) abandoned.abort();
  };
  response.once("close", abandon);

  // Revocation has to reach requests that are already talking to OpenAI, not only the
  // ones that have yet to start. The authorisation re-check above closes the window up
  // to the fetch; past it, the only signals were client-disconnect and the 11 s timeout,
  // so a device revoked mid-request still got its answer — billed to the server's key.
  const unregister = registerAbort?.(() => abandoned.abort()) ?? null;
  if (unregister) response.once("close", unregister);

  let upstream;
  try {
    upstream = await fetchImpl(config.openAIPolishURL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${config.openAIAPIKey}`,
        "content-type": "application/json",
      },
      body: forwardBody,
      redirect: "error",
      signal: AbortSignal.any([
        abandoned.signal,
        AbortSignal.timeout(config.openAIRequestTimeoutMs),
      ]),
    });
  } catch {
    // A client that hung up has nowhere to receive this.
    if (response.writableEnded || response.destroyed) return;
    // Distinguish the abort we caused ourselves. Telling a revoked device that the relay
    // could not reach OpenAI would send it into its retry ladder over a request that is
    // never going to be served again.
    if (!stillAuthorized()) {
      writeJSON(
        response,
        401,
        errorBody("转发服务器设备 Token 无效或没有权限", "relay_unauthorized"),
        { "www-authenticate": "Bearer" },
      );
      return;
    }
    writeJSON(
      response,
      502,
      errorBody("转发服务器连接 OpenAI 失败", "relay_upstream_unreachable"),
    );
    return;
  }

  if (upstream.status === 401 || upstream.status === 403) {
    writeJSON(
      response,
      424,
      errorBody(
        "转发服务器的 OpenAI API Key 无效或没有权限",
        "relay_upstream_authentication",
      ),
    );
    return;
  }

  let upstreamBody;
  try {
    upstreamBody = Buffer.from(await upstream.arrayBuffer());
  } catch {
    if (response.writableEnded || response.destroyed) return;
    writeJSON(
      response,
      502,
      errorBody(
        "转发服务器读取 OpenAI 响应失败，请稍后重试。",
        "relay_upstream_response_failed",
      ),
    );
    return;
  }
  if (upstreamBody.length > config.maxPolishResponseBytes) {
    writeJSON(
      response,
      502,
      errorBody("OpenAI 返回内容过大", "relay_upstream_response_too_large"),
    );
    return;
  }

  if (response.writableEnded || response.destroyed) return;
  response.writeHead(upstream.status, {
    "content-type": upstream.headers.get("content-type") || "application/json",
    "content-length": upstreamBody.length,
    "cache-control": "no-store",
  });
  response.end(upstreamBody);
}
