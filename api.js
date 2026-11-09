// Kindle data layer. Load AFTER the Supabase script:
// <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>
// <script src="api.js"></script>
// The anon key is safe in the browser because row level security (schema.sql) protects the data.
// NEVER put the service_role key in this app.

var SUPABASE_URL = "https://nycnvgxgextkyrnenudp.supabase.co/rest/v1/";
var SUPABASE_ANON_KEY = "DUSKWOOD";

var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

var API = {
  // ---- accounts ----
  signUp: function (email, password) { return sb.auth.signUp({ email: email, password: password }); },
  signIn: function (email, password) { return sb.auth.signInWithPassword({ email: email, password: password }); },
  signOut: function () { return sb.auth.signOut(); },
  user: async function () { var r = await sb.auth.getUser(); return r.data.user; },

  // ---- profile (birthdate must make the person 18+, enforced by the database) ----
  saveProfile: async function (p) {
    var u = await API.user();
    return sb.from("profiles").upsert({
      id: u.id, name: p.name, birthdate: p.birthdate, intent: p.intent,
      prompt_q: p.prompt_q, prompt_a: p.prompt_a, interests: p.interests
    });
  },
  myProfile: async function () {
    var u = await API.user();
    return sb.from("profiles").select("*").eq("id", u.id).maybeSingle();
  },
  uploadPhoto: async function (file) {
    var u = await API.user();
    var path = u.id + "/main-" + Date.now() + ".jpg";
    var up = await sb.storage.from("photos").upload(path, file, { contentType: file.type });
    if (up.error) return up;
    return sb.from("profiles").update({ photo_path: path }).eq("id", u.id);
  },
  photoUrl: function (path) { return path ? sb.storage.from("photos").getPublicUrl(path).data.publicUrl : null; },

  // ---- discover and swipe ----
  discover: function (intent) { return sb.rpc("discover", { p_intent: intent && intent !== "All" ? intent : null }); },
  // kind: "like" | "nope" | "super". Resolves to { matched: boolean, matchId }
  swipe: async function (targetId, kind) {
    var u = await API.user();
    var ins = await sb.from("swipes").insert({ swiper: u.id, target: targetId, kind: kind });
    if (ins.error) return { error: ins.error };
    if (kind === "nope") return { matched: false };
    var a = u.id < targetId ? u.id : targetId, b = u.id < targetId ? targetId : u.id;
    var m = await sb.from("matches").select("id").eq("user_a", a).eq("user_b", b).maybeSingle();
    return { matched: !!m.data, matchId: m.data && m.data.id };
  },
  // Rewind: removes your last swipe (only works if it did not create a match).
  rewind: async function (targetId) {
    var u = await API.user();
    return sb.from("swipes").delete().eq("swiper", u.id).eq("target", targetId);
  },

  // ---- matches and chat ----
  matches: function () {
    return sb.from("matches").select("id, created_at, user_a, user_b").order("created_at", { ascending: false });
  },
  messages: function (matchId) {
    return sb.from("messages").select("*").eq("match_id", matchId).order("created_at");
  },
  send: async function (matchId, body) {
    var u = await API.user();
    return sb.from("messages").insert({ match_id: matchId, sender: u.id, body: body });
  },
  // Live updates. Returns the channel; call sb.removeChannel(ch) to stop.
  onMessage: function (matchId, cb) {
    return sb.channel("chat-" + matchId)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages", filter: "match_id=eq." + matchId },
        function (e) { cb(e.new); })
      .subscribe();
  },
  onMatch: function (cb) {
    return sb.channel("matches")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "matches" }, function (e) { cb(e.new); })
      .subscribe();
  },

  // ---- safety (required by Google Play for dating apps) ----
  block: async function (userId) {
    var u = await API.user();
    return sb.from("blocks").insert({ blocker: u.id, blocked: userId });
  },
  report: async function (userId, reason) {
    var u = await API.user();
    return sb.from("reports").insert({ reporter: u.id, reported: userId, reason: reason });
  }
};
