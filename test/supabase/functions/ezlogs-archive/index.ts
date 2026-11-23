// An Edge Function as a Lovable / Bolt app writes one, with @ezlogs/server added as its README says:
// it archives the signed-in person's task through a service-role client, left as generated. bin/e2e copies the package's
// build into ./vendor (deno.json maps "@ezlogs/server" there), so the code under test is the package.
import { withEzlogs } from "@ezlogs/server";
import { createClient } from "npm:@supabase/supabase-js@2";

// The CORS answer every Supabase / Lovable Edge Function template carries.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(withEzlogs(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const url = Deno.env.get("SUPABASE_URL")!;
  const asPerson = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await asPerson.auth.getUser();
  if (!user) return new Response(JSON.stringify({ error: "not signed in" }), { status: 401, headers: { ...corsHeaders, "content-type": "application/json" } });

  const { taskId } = await req.json();
  // Unchanged, as Lovable writes it: @ezlogs/server stamps the calls to SUPABASE_URL by itself.
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await admin.from("tasks").update({ status: "archived" }).eq("id", taskId).eq("owner_id", user.id);
  return new Response(JSON.stringify({ archived: !error }), { headers: { ...corsHeaders, "content-type": "application/json", "x-app": "kept" } });
}));
