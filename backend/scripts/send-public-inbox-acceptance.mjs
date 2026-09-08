import { readFile } from "node:fs/promises";
import nodemailer from "nodemailer";

const to = process.argv[process.argv.indexOf("--to") + 1] || "";
const subject = process.argv[process.argv.indexOf("--subject") + 1] || "";
if (!/^[a-z0-9][a-z0-9-]{2,39}@(familydocuments\.app|familydocuments\.servicehub\.co\.nz)$/i.test(to)) {
  throw new Error("--to must be a valid current or legacy Family Documents inbox address");
}
if (!/^Synthetic inbound domain acceptance [a-z0-9-]+$/i.test(subject)) {
  throw new Error("--subject must be a synthetic acceptance-test subject");
}

const envText = await readFile(new URL("../.env.local", import.meta.url), "utf8");
const value = (key) => process.env[key] || envText.split(/\r?\n/).find((line) => line.startsWith(`${key}=`))?.slice(key.length + 1).trim() || "";
const host = value("SMTP_HOST");
const port = Number(value("SMTP_PORT"));
const user = value("SMTP_USERNAME");
const pass = value("SMTP_PASSWORD");
const fromAddress = value("SMTP_FROM_EMAIL");
if (!host || !Number.isInteger(port) || !user || !pass || !fromAddress) {
  throw new Error("SMTP configuration is incomplete");
}

const transport = nodemailer.createTransport({
  host,
  port,
  secure: port === 465,
  requireTLS: port !== 465,
  auth: { user, pass },
  tls: { minVersion: "TLSv1.2" },
});

try {
  await transport.verify();
  await transport.sendMail({
    from: { name: "Family Documents acceptance test", address: fromAddress },
    to,
    subject,
    text: "Synthetic end-to-end acceptance test for the familydocuments.app inbound email domain. No action is required.",
  });
  console.log(JSON.stringify({ sent: true, subject }));
} finally {
  transport.close();
}
