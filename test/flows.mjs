// Real app traffic through Supabase's own services (PostgREST, Auth, Storage), the way a
// Lovable / Bolt / v0 app produces it. Prints one JSON object with what each step returned.
// Usage: node flows.mjs <step>   (env: API_URL, PUBLISHABLE_KEY, SECRET_KEY)
import { createClient } from "@supabase/supabase-js";

const url = process.env.API_URL;
const anonKey = process.env.PUBLISHABLE_KEY;
const serviceKey = process.env.SECRET_KEY;
const step = process.argv[2];
const stamp = Date.now();

// The browser module's correlation header, stamped on every request of one "click".
function clientWithCorrelation(cid) {
  const fetchWithHeader = (input, init = {}) => {
    const headers = new Headers(init.headers);
    if (cid) headers.set("x-correlation-id", cid);
    return fetch(input, { ...init, headers });
  };
  return createClient(url, anonKey, { auth: { persistSession: false }, global: { fetch: fetchWithHeader } });
}

const out = {};
if (step === "user-flow") {
  const cid = `ezl_${stamp}_c0ffee01`;
  const sb = clientWithCorrelation(cid);
  const email = `ana.${stamp}@example.com`;
  const signUp = await sb.auth.signUp({ email, password: "Local-test-123!", options: { data: { full_name: "Ana Test" } } });
  out.userId = signUp.data.user?.id;
  out.email = email;
  out.cid = cid;
  out.signUp = signUp.error?.message || "ok";
  const ins = await sb.from("items").insert({ name: `item-${stamp}`, secret_token: "do-not-ship" }).select().single();
  out.insert = ins.status;
  out.itemId = ins.data?.id;
  out.update = (await sb.from("items").update({ name: `renamed-${stamp}` }).eq("id", ins.data.id)).status;
  const up = await sb.storage.from("files").upload(`${out.userId}/brief-${stamp}.txt`, new Blob(["hello"], { type: "text/plain" }), { contentType: "text/plain" });
  out.upload = up.error?.message || "ok";
  out.delete = (await sb.from("items").delete().eq("id", ins.data.id)).status;
  const dup = await sb.from("items").insert({ name: "fixed-duplicate-name" });
  const dup2 = await sb.from("items").insert({ name: "fixed-duplicate-name" });
  out.duplicate = [dup.status, dup2.status];
  out.signIn = (await sb.auth.signInWithPassword({ email, password: "Local-test-123!" })).error?.message || "ok";
} else if (step === "anon") {
  const sb = clientWithCorrelation(null);
  out.anon = (await sb.from("feedback").insert({ message: `hi ${stamp}` })).status;
} else if (step === "service") {
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  out.service = (await admin.from("items").insert({ name: `server-${stamp}` })).status;
} else if (step === "signup-only") {
  const sb = clientWithCorrelation(null);
  const r = await sb.auth.signUp({ email: `bob.${stamp}@example.com`, password: "Local-test-123!" });
  out.signUp = r.error?.message || "ok";
  out.userId = r.data.user?.id;
}
console.log(JSON.stringify(out));
