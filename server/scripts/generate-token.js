import { createHash, randomBytes } from "node:crypto";

const token = `relay_${randomBytes(32).toString("base64url")}`;
const hash = createHash("sha256").update(token, "utf8").digest("hex");

process.stdout.write(
  [
    "设备 Token（粘贴到 Mac App → 设置 → 账号与权限 → 设备 Token，只有这一次能看到）：",
    token,
    "",
    "对应的 hash（加入服务器 .env 的 RELAY_DEVICE_TOKEN_HASHES，逗号分隔）：",
    hash,
    "",
  ].join("\n"),
);
