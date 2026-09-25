import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { App } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";
import { ShopDownloads } from "@shop-management/downloads";
import { createCartCreditFeature } from "./cart-credit";
import "./styles.css";

type Role = "owner" | "worker";
type ProductUnit = "piece" | "weight";
type UserProfile = { id: string; full_name: string; email: string; role: Role; is_active: boolean };

// A customer Supabase project must be explicitly connected. Never fall back to a build-time/default project.
const SUPABASE_CONFIG_URL_KEY = "shop_management_supabase_url";
const SUPABASE_CONFIG_KEY_KEY = "shop_management_supabase_publishable_key";

let supabase: SupabaseClient | null = null;
let demoMode = false;

function createDemoClient() {
  const now = new Date();
  const iso = (daysAgo = 0, hour = 12) => {
    const d = new Date(now);
    d.setDate(d.getDate() - daysAgo);
    d.setHours(hour, 15, 0, 0);
    return d.toISOString();
  };

  const products = [
    { id:"demo-p1", name:"Tata Salt 1kg", unit_type:"piece", current_stock_base:48, purchase_price_per_base_unit:24, selling_price_per_base_unit:30, is_active:true },
    { id:"demo-p2", name:"Aashirvaad Atta 5kg", unit_type:"piece", current_stock_base:18, purchase_price_per_base_unit:210, selling_price_per_base_unit:255, is_active:true },
    { id:"demo-p3", name:"Fortune Oil 1L", unit_type:"piece", current_stock_base:27, purchase_price_per_base_unit:112, selling_price_per_base_unit:135, is_active:true },
    { id:"demo-p4", name:"Toor Dal 1kg", unit_type:"piece", current_stock_base:9, purchase_price_per_base_unit:118, selling_price_per_base_unit:145, is_active:true },
    { id:"demo-p5", name:"Basmati Rice 5kg", unit_type:"piece", current_stock_base:6, purchase_price_per_base_unit:410, selling_price_per_base_unit:475, is_active:true }
  ];
  const worker={id:"demo-worker",full_name:"Demo Worker",email:"worker@demo.shop",role:"worker",is_active:true,created_at:iso(20)};
  const owner={id:"demo-owner",full_name:"Demo Owner",email:"owner@demo.shop",role:"owner",is_active:true,created_at:iso(60)};
  const sales=[
    {id:"demo-s1",sold_at:iso(0,10),product_id:"demo-p1",worker_id:worker.id,total_sale:120,gross_profit:24,cash_amount:120,upi_amount:0,payment_mode:"cash",quantity:4,voided:false,products:{name:"Tata Salt 1kg",unit_type:"piece"},profiles:{full_name:"Demo Worker"}},
    {id:"demo-s2",sold_at:iso(0,13),product_id:"demo-p2",worker_id:worker.id,total_sale:510,gross_profit:90,cash_amount:200,upi_amount:310,payment_mode:"split",quantity:2,voided:false,products:{name:"Aashirvaad Atta 5kg",unit_type:"piece"},profiles:{full_name:"Demo Worker"}},
    {id:"demo-s3",sold_at:iso(1,16),product_id:"demo-p3",worker_id:owner.id,total_sale:270,gross_profit:46,cash_amount:0,upi_amount:270,payment_mode:"upi",quantity:2,voided:false,products:{name:"Fortune Oil 1L",unit_type:"piece"},profiles:{full_name:"Demo Owner"}},
    {id:"demo-s4",sold_at:iso(2,11),product_id:"demo-p4",worker_id:worker.id,total_sale:290,gross_profit:54,cash_amount:290,upi_amount:0,payment_mode:"cash",quantity:2,voided:false,products:{name:"Toor Dal 1kg",unit_type:"piece"},profiles:{full_name:"Demo Worker"}},
    {id:"demo-s5",sold_at:iso(5,14),product_id:"demo-p5",worker_id:owner.id,total_sale:950,gross_profit:130,cash_amount:500,upi_amount:450,payment_mode:"split",quantity:2,voided:false,products:{name:"Basmati Rice 5kg",unit_type:"piece"},profiles:{full_name:"Demo Owner"}}
  ];
  const creditors=[
    {id:"demo-c1",name:"Rahul Sharma",mobile:"9876543210",is_active:true},
    {id:"demo-c2",name:"Priya Traders",mobile:"9123456780",is_active:true}
  ];
  const creditLedger=[
    {id:"demo-cl1",creditor_id:"demo-c1",worker_id:worker.id,type:"credit_sale",amount:850,created_at:iso(3,12),profiles:{full_name:"Demo Worker",email:worker.email}},
    {id:"demo-cl2",creditor_id:"demo-c1",worker_id:owner.id,type:"payment_received",amount:300,created_at:iso(1,17),profiles:{full_name:"Demo Owner",email:owner.email}},
    {id:"demo-cl3",creditor_id:"demo-c2",worker_id:worker.id,type:"credit_sale",amount:420,created_at:iso(7,13),profiles:{full_name:"Demo Worker",email:worker.email}}
  ];
  const settingsRow={id:1,shop_id:"SHOP-DEMO0001",shop_name:"Demo Grocery Store",currency:"INR",timezone:"Asia/Kolkata",workers_can_modify_selling_price:true,allow_below_cost_sales:false,allow_zero_price_sales:false,dashboard_reset_time:"00:00"};
  const tables:any={products,sales,daily_closings:[],day_end_summaries:[],day_end_summary_lines:[],creditors,credit_ledger:creditLedger,profiles:[owner,worker],inventory_purchases:[],audit_logs:[],shop_settings:[settingsRow],automatic_day_end_snapshots:[],sale_transactions:[]};

  const clone=(v:any)=>JSON.parse(JSON.stringify(v));
  const builder=(table:string)=>{
    const state={rows:tables[table]||[],filters:[] as any[],sort:null as any,limitN:null as number|null,rangeFrom:null as number|null,rangeTo:null as number|null};
    const api:any={
      select:()=>api,
      eq:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]===val),api),
      neq:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]!==val),api),
      gte:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]>=val),api),
      gt:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]>val),api),
      lt:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]<val),api),
      lte:(col:string,val:any)=>(state.filters.push((r:any)=>r[col]<=val),api),
      in:(col:string,vals:any[])=> (state.filters.push((r:any)=>vals.includes(r[col])),api),
      order:(col:string,opt:any={})=>(state.sort={col,asc:opt.ascending!==false},api),
      limit:(n:number)=>(state.limitN=n,api),
      range:(a:number,b:number)=>(state.rangeFrom=a,state.rangeTo=b,api),
      single:async()=>{const out=run(); return {data:clone(out[0]||null),error:out.length?null:{message:"No demo row"}}},
      maybeSingle:async()=>({data:clone(run()[0]||null),error:null}),
      then:(resolve:any,reject:any)=>Promise.resolve({data:clone(run()),error:null}).then(resolve,reject),
      update:(patch:any)=>({eq:async(col:string,val:any)=>{for(const row of tables[table]||[]) if(row[col]===val) Object.assign(row,patch); return {data:null,error:null};}}),
      insert:async(payload:any)=>{const arr=Array.isArray(payload)?payload:[payload]; tables[table]=(tables[table]||[]).concat(clone(arr)); return {data:clone(arr),error:null};},
      delete:()=>({eq:async(col:string,val:any)=>{tables[table]=(tables[table]||[]).filter((r:any)=>r[col]!==val);return {data:null,error:null};}})
    };
    const run=()=>{let out=state.rows.filter((r:any)=>state.filters.every(f=>f(r))); if(state.sort) out.sort((a:any,b:any)=>{const av=a[state.sort.col],bv=b[state.sort.col];return av===bv?0:(av>bv?1:-1)*(state.sort.asc?1:-1)}); if(state.rangeFrom!==null) out=out.slice(state.rangeFrom,state.rangeTo!+1); if(state.limitN!==null) out=out.slice(0,state.limitN); return out;};
    return api;
  };
  const demo:any={
    from:(table:string)=>builder(table),
    rpc:async(name:string,args:any={})=>{
      if(name==="get_or_create_creditor"){let x=creditors.find((c:any)=>c.name.toLowerCase()===String(args.p_name||"").toLowerCase()); if(!x){x={id:"demo-c"+Date.now(),name:String(args.p_name||"Demo Customer"),mobile:String(args.p_mobile||""),is_active:true};creditors.push(x)} return {data:{ok:true,creditor_id:x.id},error:null};}
      if(name==="receive_credit_payment"){creditLedger.push({id:"demo-cl"+Date.now(),creditor_id:args.p_creditor_id,worker_id:profile?.id,type:"payment_received",amount:Number(args.p_amount||0),created_at:new Date().toISOString(),profiles:{full_name:profile?.full_name||"Demo Owner",email:profile?.email||""}});return {data:{ok:true},error:null};}
      if(name==="verify_shop_management"||name==="verify_cart_credit_schema"||name==="activate_user_after_email_verification") return {data:{ok:true},error:null};
      return {data:{ok:true},error:null};
    },
    auth:{
      getSession:async()=>({data:{session:{user:{id:owner.id,email:owner.email,email_confirmed_at:new Date().toISOString()}}}}),
      signOut:async()=>({error:null}),
      signInWithPassword:async()=>({data:{session:{user:{id:owner.id,email:owner.email,email_confirmed_at:new Date().toISOString()}}},error:null}),
      onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
      updateUser:async()=>({error:null}),
      resetPasswordForEmail:async()=>({error:null})
    },
    channel:()=>({on(){return this},subscribe(){return this},unsubscribe(){}})
  };
  return demo;
}


function loadSupabaseConnection() {
  const url = (localStorage.getItem(SUPABASE_CONFIG_URL_KEY) || "").trim();
  const key = (localStorage.getItem(SUPABASE_CONFIG_KEY_KEY) || "").trim();
  if (!url || !key) {
    supabase = null;
    return false;
  }
  supabase = createClient(url.replace(/\/$/, ""), key);
  return true;
}

function savedSupabaseConnection() {
  return {
    url: localStorage.getItem(SUPABASE_CONFIG_URL_KEY) || "",
    key: localStorage.getItem(SUPABASE_CONFIG_KEY_KEY) || ""
  };
}

loadSupabaseConnection();

const app = document.querySelector<HTMLDivElement>("#app")!;

const LICENSE_CONTROL_URL = "https://iwgqmmawaaoszlkovnuz.supabase.co";
const LICENSE_CONTROL_KEY = "sb_publishable_zlGFKybWC4N3XlzPB0pIuw_VPuIIPc1";
const licenseSupabase = createClient(LICENSE_CONTROL_URL, LICENSE_CONTROL_KEY);
const LICENSE_STORAGE_KEY = "shop_management_license";
const LICENSE_DEVICE_KEY = "shop_management_license_device";
const AUTH_REDIRECT_URL = "shopmanagement://auth-callback";

function licenseDeviceId() {
  let id = localStorage.getItem(LICENSE_DEVICE_KEY);
  if (!id) {
    id = typeof crypto.randomUUID === "function"
      ? crypto.randomUUID()
      : "device-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
    localStorage.setItem(LICENSE_DEVICE_KEY, id);
  }
  return id;
}

function savedLicense() {
  return localStorage.getItem(LICENSE_STORAGE_KEY) || "";
}

async function verifyShopLicense(key: string) {
  const { data, error } = await licenseSupabase.rpc("verify_shop_license", {
    p_license_key: key.trim(),
    p_device_id: licenseDeviceId()
  });
  if (error) throw new Error(error.message);
  if (!data?.ok) throw new Error(data?.error || "License verification failed.");
  const assignedShopId = String(data.shop_id || "").trim().toUpperCase();
  if (!assignedShopId) {
    throw new Error("License activated but no Shop ID was assigned. Contact the seller.");
  }
  localStorage.setItem(LICENSE_STORAGE_KEY, key.trim().toUpperCase());
  localStorage.setItem("shop_management_shop_id", assignedShopId);
  return data;
}

function hasCustomerSupabaseConnection() {
  return Boolean(
    localStorage.getItem(SUPABASE_CONFIG_URL_KEY) &&
    localStorage.getItem(SUPABASE_CONFIG_KEY_KEY)
  );
}

async function downloadShopSql() {
  try {
    const response = await fetch("/shop-management.sql");
    if (!response.ok) throw new Error("Could not load the SQL setup text.");

    const sql = await response.text();

    app.innerHTML = `
      <div class="login">
        <div class="login-card license-card" style="width:min(1100px,96vw);max-width:1100px">
          <div class="brand big">SHOP MANAGEMENT SQL</div>
          <p class="muted">Copy the complete SQL below and paste it into your Supabase SQL Editor.</p>
          <div class="notice">
            <strong>Shop ID:</strong> This SQL is generic. Do not manually replace the Shop ID.
            The app generates/synchronizes the Shop ID during setup.
          </div>
          <textarea id="shopSqlText" readonly style="width:100%;min-height:55vh;box-sizing:border-box;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;line-height:1.45;padding:14px;border-radius:12px;border:1px solid var(--border,#334155);background:#0b1220;color:#e5e7eb;resize:vertical"></textarea>
          <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:12px">
            <button id="copyShopSqlBtn" class="primary" type="button">Copy Full SQL</button>
            <button id="backShopSqlBtn" class="ghost" type="button">Back</button>
          </div>
        </div>
      </div>`;
    
    const textarea = document.querySelector<HTMLTextAreaElement>("#shopSqlText");
    if (textarea) textarea.value = sql;

    document.querySelector<HTMLButtonElement>("#copyShopSqlBtn")?.addEventListener("click", async () => {
      if (!textarea) return;
      try {
        await navigator.clipboard.writeText(textarea.value);
        notify("Full SQL copied. Paste it into Supabase SQL Editor.", "success");
      } catch {
        textarea.focus();
        textarea.select();
        document.execCommand("copy");
        notify("Full SQL copied. Paste it into Supabase SQL Editor.", "success");
      }
    });

    document.querySelector<HTMLButtonElement>("#backShopSqlBtn")?.addEventListener("click", () => {
      supabaseConnectionView("", "owner");
    });
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), "error");
  }
}

async function supabaseConnectionView(message = "", mode: "owner" = "owner", afterConnect?: () => void) {
  let shopId = localStorage.getItem("shop_management_shop_id") || "";
  let enteredUrl = "";
  let enteredKey = "";

  const render = (errorMessage = "", verifyMode = false) => {
    app.innerHTML = "<div class=\"login\"><div class=\"login-card license-card\">" +
      "<div class=\"brand big\">SHOP MANAGEMENT</div>" +
      "<p class=\"muted\">" + (afterConnect ? "Change Supabase project" : "Connect Supabase project") + "</p>" +
      (errorMessage ? "<div class=\"notice danger\">" + escapeHtml(errorMessage) + "</div>" : "") +
      "<div class=\"notice\"><strong>Shop ID:</strong> " + escapeHtml(shopId) + "<br>Enter your own Supabase project URL and publishable key. Never enter a secret/service key.</div>" +
      "<form id=\"supabaseProjectForm\"><label>Supabase Project URL<input name=\"supabase_url\" required placeholder=\"https://xxxxx.supabase.co\" value=\"" + escapeHtml(enteredUrl) + "\"></label>" +
      "<label>Publishable Project Key<input name=\"supabase_key\" required autocomplete=\"off\" placeholder=\"sb_publishable_...\" value=\"" + escapeHtml(enteredKey) + "\"></label>" +
      "<button class=\"primary\" type=\"submit\">" + (verifyMode ? "Verify Database" : "Connect Project") + "</button></form>" +
      (verifyMode ? "<div class=\"notice\"><strong>1.</strong> Open the SQL text below and copy it.<br><strong>2.</strong> Run it in Supabase SQL Editor.<br><strong>3.</strong> Press Verify Database.</div><button id=\"downloadSqlBtn\" class=\"ghost\" style=\"width:100%\">View / Copy Shop Management SQL</button>" : "") +
      "<button id=\"backConnectionBtn\" type=\"button\" class=\"ghost\">Back</button></div></div>";

    document.querySelector("#downloadSqlBtn")?.addEventListener("click", () => void downloadShopSql());
    document.querySelector("#backConnectionBtn")?.addEventListener("click", () => {
      if (afterConnect && profile) renderDashboard(); else loginView("", "owner");
    });

    document.querySelector<HTMLFormElement>("#supabaseProjectForm")?.addEventListener("submit", async event => {
      event.preventDefault();
      const fd = new FormData(event.currentTarget as HTMLFormElement);
      enteredUrl = String(fd.get("supabase_url") || "").trim().replace(/\/+$/, "");
      enteredKey = String(fd.get("supabase_key") || "").trim();
      const button = document.querySelector<HTMLButtonElement>("#supabaseProjectForm button");
      if (button) { button.disabled = true; button.textContent = verifyMode ? "Verifying..." : "Checking project..."; }
      try {
        if (!verifyMode) {
          if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(enteredUrl)) throw new Error("Enter a valid Supabase project URL.");
          if (!enteredKey) throw new Error("Publishable key is required.");
          const probe = createClient(enteredUrl, enteredKey);
          const probeResult = await probe.auth.getSession();
          if (probeResult.error) throw new Error("Could not connect to this Supabase project: " + probeResult.error.message);
          render("", true);
          return;
        }

        const verifyClient = createClient(enteredUrl, enteredKey);

        // The license service already generated the canonical Shop ID.
        // The customer's generic SQL does not contain it. Initialize it automatically here.
        const init = await verifyClient.rpc("initialize_shop", { p_shop_id: null });
        if (init.error) throw new Error(init.error.message);
        if (!init.data?.ok) throw new Error(init.data?.error || "Could not initialize this shop.");

        const generatedShopId = String(init.data?.shop_id || "").trim().toUpperCase();
        if (!/^SHOP-[A-F0-9]{10}$/.test(generatedShopId)) throw new Error("The database did not return a valid generated Shop ID.");
        shopId = generatedShopId;
        localStorage.setItem("shop_management_shop_id", generatedShopId);

        const vr = await verifyClient.rpc("verify_shop_management", { p_expected_shop_id: generatedShopId });
        if (vr.error) throw new Error(vr.error.message);
        if (!vr.data?.ok) {
          const missing = Array.isArray(vr.data?.missing) ? vr.data.missing.join(", ") : "required database items";
          throw new Error("Database is not ready. Missing or incorrect: " + missing + ". Run the downloaded SQL file, then press Verify Database again.");
        }

        const central = await licenseSupabase.rpc("connect_shop_project", {
          p_license_key: savedLicense(),
          p_device_id: licenseDeviceId(),
          p_shop_name: settings.shop_name || "My Shop",
          p_owner_email: "",
          p_supabase_url: enteredUrl,
          p_supabase_publishable_key: enteredKey,
          p_shop_id: generatedShopId
        });
        if (central.error) throw new Error(central.error.message);
        if (!central.data?.ok) throw new Error(central.data?.error || "Could not save the Supabase connection.");

        localStorage.setItem(SUPABASE_CONFIG_URL_KEY, enteredUrl);
        localStorage.setItem(SUPABASE_CONFIG_KEY_KEY, enteredKey);
        loadSupabaseConnection();
        notify("Supabase project verified and connected.", "success");
        if (afterConnect) afterConnect();
        else loginView("Supabase is connected and verified. Create your owner account.", "owner");
      } catch (err) {
        if (button) { button.disabled = false; button.textContent = verifyMode ? "Verify Database" : "Connect Project"; }
        render(err instanceof Error ? err.message : String(err), verifyMode);
      }
    });
  };

  if (!shopId) return loginView("Shop ID is missing. Please activate the license again.", "owner");
  render(message, false);
}


async function registerAccountRecovery(email: string, role: "owner" | "worker", shopId: string) {
  const normalizedEmail = email.trim().toLowerCase();
  const normalizedShopId = shopId.trim().toUpperCase();
  if (!normalizedEmail || !normalizedShopId) return;
  const { data, error } = await licenseSupabase.rpc("register_account_recovery", {
    p_email: normalizedEmail,
    p_role: role,
    p_shop_id: normalizedShopId
  });
  if (error) console.warn("Account recovery registration failed:", error.message);
  else if (!data?.ok) console.warn("Account recovery registration failed:", data?.error || "unknown error");
}

async function recoverAccountView(role: "owner" | "worker", message = "") {
  let email = "";
  let password = "";
  let matches: Array<{shop_id:string;shop_name:string;supabase_url:string;supabase_publishable_key:string}> = [];

  const render = (errorMessage = "") => {
    app.innerHTML = `
      <div class="login"><div class="login-card license-card">
        <div class="brand big">SHOP MANAGEMENT</div>
        <p class="muted">${role === "owner" ? "Owner account recovery" : "Worker account recovery"}</p>
        ${errorMessage ? `<div class="notice danger">${escapeHtml(errorMessage)}</div>` : ""}
        <div class="notice">
          Enter the email and password already registered for this shop.
          The app will find the connected shop automatically after a reinstall.
        </div>
        <form id="accountRecoveryForm">
          <label>Email<input name="email" type="email" required autocomplete="email" value="${escapeHtml(email)}"></label>
          <label>Password<input name="password" type="password" required minlength="6" autocomplete="current-password"></label>
          <button class="primary" type="submit">Find My Shop & Sign In</button>
        </form>
        ${matches.length > 1 ? `
          <div class="notice"><strong>Multiple shops found.</strong> Choose the shop you want to open.</div>
          <div id="recoveryMatches" class="role-choice">
            ${matches.map((m,i)=>`<button type="button" class="${i===0?"primary":"ghost"} recovery-shop" data-shop-id="${escapeHtml(m.shop_id)}">${escapeHtml(m.shop_name)} · ${escapeHtml(m.shop_id)}</button>`).join("")}
          </div>
        ` : ""}
        <button id="recoveryBack" class="ghost" type="button">Back</button>
      </div></div>`;

    document.querySelector<HTMLFormElement>("#accountRecoveryForm")?.addEventListener("submit", async e => {
      e.preventDefault();
      const fd = new FormData(e.currentTarget as HTMLFormElement);
      email = String(fd.get("email") || "").trim().toLowerCase();
      password = String(fd.get("password") || "");
      if (!email || password.length < 6) return render("Enter your registered email and password.");

      const button = document.querySelector<HTMLButtonElement>("#accountRecoveryForm button");
      if (button) { button.disabled = true; button.textContent = "Finding shop..."; }

      try {
        const { data, error } = await licenseSupabase.rpc("resolve_account_recovery", {
          p_email: email,
          p_role: role
        });
        if (error) throw new Error(error.message);
        if (!data?.ok) throw new Error(data?.error || "Recovery lookup failed.");
        const found = Array.isArray(data.matches) ? data.matches : [];
        if (!found.length) throw new Error("No shop is registered for this email yet. Sign in once on the current installation, then recovery will be available after reinstall.");
        matches = found;
        if (matches.length > 1) return render("");
        await connectRecoveredShop(matches[0]);
      } catch (err) {
        if (button) { button.disabled = false; button.textContent = "Find My Shop & Sign In"; }
        render(err instanceof Error ? err.message : String(err));
      }
    });

    document.querySelectorAll<HTMLButtonElement>(".recovery-shop").forEach(button => {
      button.addEventListener("click", () => {
        const selected = matches.find(m => m.shop_id === button.dataset.shopId);
        if (selected) void connectRecoveredShop(selected);
      });
    });

    document.querySelector("#recoveryBack")?.addEventListener("click", () => loginView());
  };

  const connectRecoveredShop = async (match: {shop_id:string;shop_name:string;supabase_url:string;supabase_publishable_key:string}) => {
    try {
      app.innerHTML = `<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><p class="muted">Signing in...</p><div class="notice">Connecting to ${escapeHtml(match.shop_name)} (${escapeHtml(match.shop_id)})</div></div></div>`;
      const recoveredClient = createClient(match.supabase_url, match.supabase_publishable_key);
      const { data, error } = await recoveredClient.auth.signInWithPassword({ email, password });
      if (error) throw new Error(error.message);
      if (!data.session) throw new Error("No session was returned. Please verify your email and try again.");

      supabase = recoveredClient;
      localStorage.setItem(SUPABASE_CONFIG_URL_KEY, match.supabase_url);
      localStorage.setItem(SUPABASE_CONFIG_KEY_KEY, match.supabase_publishable_key);
      localStorage.setItem("shop_management_shop_id", match.shop_id);
      loadSupabaseConnection();

      const { data: signedInProfile, error: profileError } = await supabase
        .from("profiles")
        .select("role,shop_id")
        .eq("id", data.session.user.id)
        .single();
      if (profileError || !signedInProfile) throw new Error("Could not load your account profile.");
      if (signedInProfile.role !== role) throw new Error("This account belongs to a different access type.");

      if (role === "worker") {
        const registeredShopId = String(signedInProfile.shop_id || match.shop_id).trim().toUpperCase();
        localStorage.setItem("shop_management_shop_id", registeredShopId);
      }

      await registerAccountRecovery(email, role, localStorage.getItem("shop_management_shop_id") || match.shop_id);

      if (role === "owner") {
        const reb = await licenseSupabase.rpc("rebind_shop_license_device", {
          p_email: email,
          p_shop_id: match.shop_id,
          p_device_id: licenseDeviceId()
        });
        if (reb.error || !reb.data?.ok) throw new Error(reb.error?.message || reb.data?.error || "Could not rebind the owner license to this device.");
      }

      await loadSession(data.session);
    } catch (err) {
      supabase = null;
      localStorage.removeItem(SUPABASE_CONFIG_URL_KEY);
      localStorage.removeItem(SUPABASE_CONFIG_KEY_KEY);
      render(err instanceof Error ? err.message : String(err));
    }
  };

  render(message);
}

async function workerProjectLoginView(message = "") {
  let shopId = "";
  const render = (errorMessage = "") => {
    app.innerHTML = "<div class=\"login\"><div class=\"login-card license-card\"><div class=\"brand big\">SHOP MANAGEMENT</div><p class=\"muted\">Worker access</p>" +
      (errorMessage ? "<div class=\"notice danger\">" + escapeHtml(errorMessage) + "</div>" : "") +
      "<div class=\"notice\">Enter the Shop ID provided by your shop owner. Workers never enter the license key.</div>" +
      "<form id=\"workerShopForm\"><label>Shop ID<input name=\"shop_id\" required placeholder=\"SHOP-XXXXXXXXXX\" value=\"" + escapeHtml(shopId) + "\"></label><button class=\"primary\" type=\"submit\">Continue</button></form>" +
      "<button id=\"workerBack\" class=\"ghost\">Back</button></div></div>";
    document.querySelector("#workerBack")?.addEventListener("click", () => loginView());
    document.querySelector<HTMLFormElement>("#workerShopForm")?.addEventListener("submit", async event => {
      event.preventDefault();
      shopId = String(new FormData(event.currentTarget as HTMLFormElement).get("shop_id") || "").trim().toUpperCase();
      const button = document.querySelector<HTMLButtonElement>("#workerShopForm button");
      if (button) { button.disabled = true; button.textContent = "Finding shop..."; }
      try {
        const { data, error } = await licenseSupabase.rpc("resolve_shop_connection", { p_shop_id: shopId });
        if (error) throw new Error(error.message);
        if (!data?.ok) throw new Error(data?.error || "Shop ID is not active.");
        localStorage.setItem("shop_management_shop_id", shopId);
        localStorage.setItem(SUPABASE_CONFIG_URL_KEY, data.supabase_url);
        localStorage.setItem(SUPABASE_CONFIG_KEY_KEY, data.supabase_publishable_key);
        loadSupabaseConnection();
        loginView("", "worker");
      } catch (err) {
        if (button) { button.disabled = false; button.textContent = "Continue"; }
        render(err instanceof Error ? err.message : String(err));
      }
    });
  };
  render(message);
}


async function licenseView(message = "") {
  const render = (errorMessage = "") => {
    app.innerHTML = `
      <div class="login"><div class="login-card license-card">
        <div class="brand big">SHOP MANAGEMENT</div>
        <p class="muted">License activation</p>
        ${errorMessage ? `<div class="notice danger">${escapeHtml(errorMessage)}</div>` : ""}
        <div class="notice">Enter the license key provided by your seller to continue.</div>
        <form id="licenseForm">
          <label>License key<input name="license_key" autocomplete="off" placeholder="SM-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX" required></label>
          <button class="primary" type="submit">Activate License</button>
        </form>
        <p class="tiny">Your license is checked securely online. No seller service key is stored in this app.</p>
      </div></div>`;
    document.querySelector<HTMLInputElement>("#licenseForm input")!.value = savedLicense();
    document.querySelector<HTMLFormElement>("#licenseForm")!.addEventListener("submit", async e => {
      e.preventDefault();
      const key = String(new FormData(e.currentTarget as HTMLFormElement).get("license_key") || "").trim();
      if (!key) return;
      const button = document.querySelector<HTMLButtonElement>("#licenseForm button");
      if (button) { button.disabled = true; button.textContent = "Checking..."; }
      try {
        await verifyShopLicense(key);
        if (!hasCustomerSupabaseConnection()) return supabaseConnectionView("", "owner");
        loadSupabaseConnection();
        loginView("", "owner");
      } catch (err) {
        if (button) { button.disabled = false; button.textContent = "Activate License"; }
        render(err instanceof Error ? err.message : String(err));
      }
    });
  };
  render(message);
}

async function ensureShopLicense() {
  const key = savedLicense();
  if (!key) return false;
  try {
    await verifyShopLicense(key);
    return true;
  } catch {
    localStorage.removeItem(LICENSE_STORAGE_KEY);
    return false;
  }
}


const formatDateTime = (value: string | Date) => new Intl.DateTimeFormat("en-IN", {
  timeZone: settings.timezone || "Asia/Kolkata",
  year: "numeric", month: "2-digit", day: "2-digit",
  hour: "numeric", minute: "2-digit", hour12: true
}).format(new Date(value));

const format12HourTime = (value: string) => {
  const [hRaw, mRaw] = String(value || "00:00").split(":").map(Number);
  const h = Number.isFinite(hRaw) ? hRaw : 0;
  const m = Number.isFinite(mRaw) ? mRaw : 0;
  const period = h >= 12 ? "PM" : "AM";
  const hour12 = h % 12 || 12;
  return hour12 + ":" + String(m).padStart(2, "0") + " " + period;
};

const money = (n: number) => {
  const currency = String(settings?.currency || "INR").trim().toUpperCase();
  try {
    return new Intl.NumberFormat("en-IN", {
      style: "currency", currency, maximumFractionDigits: 2
    }).format(n || 0);
  } catch {
    return currency + " " + Number(n || 0).toFixed(2);
  }
};

const qty = (n: number, unit: ProductUnit) =>
  unit === "piece" ? `${n} pcs` : `${(n / 1000).toFixed(3).replace(/0+$/, "").replace(/\.$/, "")} kg`;

const saleQty = (s: any) => {
  const unit = s.products?.unit_type as ProductUnit | undefined;
  const n = Number(s.quantity_display ?? 0);
  if (unit === "piece" || s.sold_unit === "piece") return n + " pcs";
  if (s.sold_unit === "kg") return n + " kg";
  if (s.sold_unit === "grams") return n + " g";
  return Number(s.quantity_base ?? n) + " g";
};

const productQtyFromBase = (base: number, unit: ProductUnit) =>
  unit === "piece" ? base + " pcs" : (base / 1000).toFixed(3).replace(/0+$/, "").replace(/\.$/, "") + " kg";

const auditDescription = (a: any) => {
  const d = a.details || {};
  if (a.action === "sale_created") {
    const payment = d.payment_mode === "split"
      ? "Cash " + money(Number(d.cash_amount || 0)) + " + UPI " + money(Number(d.upi_amount || 0))
      : String(d.payment_mode || "cash").toUpperCase();
    return saleQty({quantity_display:d.quantity_display, quantity_base:d.quantity_base, sold_unit:d.sold_unit, products:{unit_type:d.unit_type}})
      + " · " + payment + " · " + money(Number(d.total_sale || 0));
  }
  if (a.action === "purchase_added") return "Purchased " + (d.quantity_display || d.quantity_base) + " " + (d.unit || "") + " · " + money(Number(d.total_cost || 0));
  if (a.action === "product_created") return "Created product · opening " + (d.opening_stock_base || 0) + " base · sell " + money(Number(d.selling_price || 0));
  if (a.action === "sale_voided") return "Voided sale · " + (d.reason || "Correction");
  if (a.action === "closing_submitted") return "Expected " + money(Number(d.expected_total || 0)) + " · cash " + money(Number(d.cash || 0)) + " · UPI " + money(Number(d.upi || 0));
  if (a.action === "closing_approved") return "Closing approved";
  if (a.action === "closing_locked") return "Closing locked";
  if (a.action === "day_end_confirmed") return "Day-end confirmed and sales recorded";
  if (a.action === "day_end_submitted") return "Day-end submitted for owner confirmation";
  if (a.action === "update" && a.entity_type === "products") {
    const oldP=d.old||{}, newP=d.new||{}, changes:string[]=[];
    if(oldP.name!==newP.name) changes.push("name");
    if(oldP.purchase_price_per_base_unit!==newP.purchase_price_per_base_unit) changes.push("purchase price");
    if(oldP.selling_price_per_base_unit!==newP.selling_price_per_base_unit) changes.push("selling price");
    if(oldP.low_stock_threshold_base!==newP.low_stock_threshold_base) changes.push("low-stock threshold");
    if(oldP.is_active!==newP.is_active) changes.push("active status");
    return changes.length ? "Product settings changed: "+changes.join(", ") : "Product updated";
  }
  if (a.action === "update" && a.entity_type === "day_end_summaries") return "Status: " + (d.old?.status || "?") + " → " + (d.new?.status || "?");
  if (a.action === "update" && a.entity_type === "shop_settings") return "Shop settings changed";
  return a.action === "update" || a.action === "insert" ? "Record changed" : a.action;
};

const escapeHtml = (s: string) =>
  String(s ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#039;" }[c]!));

const wallClockParts = (d = new Date()) => {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: settings.timezone || "Asia/Kolkata",
    year:"numeric", month:"2-digit", day:"2-digit", hour:"2-digit", minute:"2-digit",
    second:"2-digit", hourCycle:"h23"
  }).formatToParts(d).map(p => [p.type, p.value]));
  return { date: parts.year + "-" + parts.month + "-" + parts.day, hour:Number(parts.hour), minute:Number(parts.minute) };
};

const localCalendarDate = () => wallClockParts().date;

const localDate = () => {
  const reset = String(settings.dashboard_reset_time || "00:00");
  const parts = reset.split(":").map(Number);
  const now = wallClockParts();
  const beforeReset = now.hour * 60 + now.minute < parts[0] * 60 + parts[1];
  return beforeReset ? shiftBusinessDate(now.date, -1) : now.date;
};

const shiftBusinessDate = (date: string, days: number) => {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};

const zonedWallToUtc = (date: string, time: string) => {
  const timeZone = settings.timezone || "Asia/Kolkata";
  const target = Date.parse(date + "T" + time + ":00Z");
  let guess = target;
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone, year:"numeric", month:"2-digit", day:"2-digit",
    hour:"2-digit", minute:"2-digit", second:"2-digit", hourCycle:"h23"
  });
  for (let i = 0; i < 3; i++) {
    const parts = Object.fromEntries(formatter.formatToParts(new Date(guess)).map(p => [p.type, p.value]));
    const displayedAsUtc = Date.UTC(
      Number(parts.year), Number(parts.month) - 1, Number(parts.day),
      Number(parts.hour), Number(parts.minute), Number(parts.second)
    );
    guess += target - displayedAsUtc;
  }
  return new Date(guess).toISOString();
};

const businessDayBounds = (date = localDate()) => {
  const reset = String(settings.dashboard_reset_time || "00:00");
  return {
    start: zonedWallToUtc(date, reset),
    end: zonedWallToUtc(shiftBusinessDate(date, 1), reset)
  };
};

const dateDaysAgo = (days: number) =>
  businessDayBounds(shiftBusinessDate(localDate(), -days)).start;

const dashboardResetLabel = () => format12HourTime(String(settings.dashboard_reset_time || "00:00"));
let lastBusinessDate = "";
let dashboardResetTimer: ReturnType<typeof setInterval> | null = null;
let passwordRecoveryMode = false;

const reconciliation = (difference: number) => difference === 0 ? "MATCHED" : difference < 0 ? "SHORT " + money(Math.abs(difference)) : "EXTRA " + money(difference);

const notify = (message: string, kind: "success" | "error" | "info" = "info") => {
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.textContent = message;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 3500);
};

let profile: UserProfile | null = null;
let products: any[] = [];
let todaySales: any[] = [];
let historySales: any[] = [];
let closings: any[] = [];
let workers: any[] = [];
let dayEnds: any[] = [];
let dayEndLines: any[] = [];
let purchases: any[] = [];
let auditLogs: any[] = [];
let creditors: any[] = [];
let creditLedger: any[] = [];
let settings: any = { shop_name: "My Shop", currency: "INR", timezone: "Asia/Kolkata", workers_can_modify_selling_price: false };
let realtimeChannel: any = null;
let refreshTimer: ReturnType<typeof setTimeout> | null = null;
let refreshInFlight = false;
let refreshQueued = false;
let workerApprovalTimer: ReturnType<typeof setInterval> | null = null;

const cartCreditFeature = createCartCreditFeature({
  getSupabase: () => supabase,
  getProfile: () => profile,
  getProducts: () => products,
  getCreditors: () => creditors,
  getCreditLedger: () => creditLedger,
  getSettings: () => settings,
  money,
  escapeHtml,
  notify,
  refresh,
  renderDashboard,
  localDate,
  businessDayBounds,
  formatDateTime,
  saleQty,
});

function rootShell(title: string, body: string) {
  document.title = settings.shop_name ? String(settings.shop_name) + " — Shop Management" : "Shop Management";
  app.innerHTML = `
    <div class="shell">
      <header class="topbar">
        <div><div class="brand">${escapeHtml(settings.shop_name || "SHOP MANAGEMENT")}</div><div class="muted">${escapeHtml(title)}</div></div>
        <div class="topbar-actions"><button id="refreshAppBtn" class="ghost">↻ Refresh</button><button id="logoutBtn" class="ghost">Logout</button></div>
      </header>
      <main class="content">${body}</main>
    </div>`;
}

function queueRealtimeRefresh() {
  if (profile?.role === "worker" && !profile.is_active) {
    void checkWorkerApproval();
    return;
  }
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    void refresh();
  }, 250);
}

function stopWorkerApprovalWatcher() {
  if (workerApprovalTimer) {
    clearInterval(workerApprovalTimer);
    workerApprovalTimer = null;
  }
}

function showWorkerPendingApproval() {
  stopWorkerApprovalWatcher();
  app.innerHTML = `
    <div class="login"><div class="login-card">
      <div class="brand big">SHOP MANAGEMENT</div>
      <p class="muted">Worker access</p>
      <div class="notice">
        <h3>Waiting for shop owner approval</h3>
        <p>Your email is verified. Your account is now waiting for the shop owner to approve access.</p>
        <p class="tiny">Keep this app open. Once the owner approves your account, this screen will automatically change to the Worker Dashboard.</p>
      </div>
      <div class="notice"><strong>Shop ID:</strong> ${escapeHtml(localStorage.getItem("shop_management_shop_id") || "Not available")}</div>
      <button id="pendingLogoutBtn" class="ghost">Logout</button>
    </div></div>`;
  document.querySelector("#pendingLogoutBtn")?.addEventListener("click", async () => {
    stopWorkerApprovalWatcher();
    await supabase?.auth.signOut();
  });
  workerApprovalTimer = setInterval(() => { void checkWorkerApproval(); }, 3000);
}

async function checkWorkerApproval() {
  if (!supabase || !profile || profile.role !== "worker" || profile.is_active) {
    stopWorkerApprovalWatcher();
    return;
  }

  const { data, error } = await supabase
    .from("profiles")
    .select("id,full_name,email,role,is_active")
    .eq("id", profile.id)
    .single();

  if (error || !data) return;

  if (data.role !== "worker") {
    stopWorkerApprovalWatcher();
    await supabase.auth.signOut();
    return;
  }

  if (!data.is_active) return;

  profile = data as UserProfile;
  stopWorkerApprovalWatcher();
  if (!demoMode) setupRealtime();
  notify("Worker account approved. Opening dashboard…", "success");
  await refresh();
}

function setupRealtime() {
  if (!supabase || !profile) return;
  realtimeChannel?.unsubscribe();
  realtimeChannel = supabase.channel("shop-live")
    .on("postgres_changes", { event: "*", schema: "public", table: "products" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "sales" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "daily_closings" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "day_end_summaries" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "shop_settings" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "inventory_purchases" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "day_end_summary_lines" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "audit_logs" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "creditors" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "credit_ledger" }, queueRealtimeRefresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "sale_transactions" }, queueRealtimeRefresh)
    .subscribe((status) => {
      if (status === "SUBSCRIBED") console.info("Realtime connected");
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
        console.warn("Realtime connection issue:", status);
      }
    });
}

async function refresh() {
  if (!supabase || !profile) return;
  if (refreshInFlight) {
    refreshQueued = true;
    return;
  }
  refreshInFlight = true;
  try {
  const { data: st, error: stError } = await supabase!.from("shop_settings").select("*").eq("id",1).single();
  if (stError) notify("Could not refresh shop settings: " + stError.message, "error");
  if (st) settings = st;
  lastBusinessDate = localDate();
  const { data: p, error: pError } = await supabase.from("products").select("*").eq("is_active", true).order("name");
  if (pError) notify("Could not refresh products: " + pError.message, "error");
  else products = p || [];
  const todayBounds = businessDayBounds();
  const { data: s, error: sError } = await supabase.from("sales").select("*, products(name, unit_type), profiles:worker_id(full_name)").gte("sold_at", todayBounds.start).lt("sold_at", todayBounds.end).order("sold_at", {ascending:false});
  if (sError) notify("Could not refresh today's sales: " + sError.message, "error");
  else { todaySales = s || []; (window as any).__shopManagementTodaySales = todaySales; }
  const { data: hs, error: hsError } = await supabase.from("sales").select("*, products(name, unit_type), profiles:worker_id(full_name)").gte("sold_at", dateDaysAgo(90)).lt("sold_at", todayBounds.end).order("sold_at", {ascending:false}).limit(2000);
  if (hsError) notify("Could not refresh sales history: " + hsError.message, "error");
  else historySales = hs || [];
  const { data: c, error: cError } = await supabase.from("daily_closings").select("*, profiles:worker_id(full_name)").order("business_date", {ascending:false}).limit(60);
  if (cError) notify("Could not refresh closings: " + cError.message, "error");
  else closings = c || [];
  const { data: de, error: deError } = await supabase.from("day_end_summaries").select("*, profiles:worker_id(full_name)").order("business_date", {ascending:false}).limit(60);
  if (deError) notify("Could not refresh day-end history: " + deError.message, "error");
  else dayEnds = de || [];
  const { data: cr, error: crError } = await supabase.from("creditors").select("*").eq("is_active", true).order("name");
  if (crError) {
    creditors = [];
    if (!String(crError.message).toLowerCase().includes("could not find the table") && !String(crError.message).toLowerCase().includes("relation")) {
      notify("Could not refresh creditors: " + crError.message, "error");
    }
  } else creditors = cr || [];
  const { data: cl, error: clError } = await supabase.from("credit_ledger").select("*, profiles:worker_id(full_name,email)").order("created_at", { ascending: false }).limit(5000);
  if (clError) {
    creditLedger = [];
    if (!String(clError.message).toLowerCase().includes("could not find the table") && !String(clError.message).toLowerCase().includes("relation")) {
      notify("Could not refresh credit ledger: " + clError.message, "error");
    }
  } else creditLedger = cl || [];
  const dayEndIds = dayEnds.map(d => d.id).filter(Boolean);
  if (dayEndIds.length) {
    const { data: del, error: delError } = await supabase.from("day_end_summary_lines").select("*, products(name, unit_type)").in("summary_id", dayEndIds).order("created_at");
    if (delError) notify("Could not refresh day-end items: " + delError.message, "error");
    else dayEndLines = del || [];
  } else dayEndLines = [];
  if (profile!.role === "owner") {
    await loadAudit();
    const { data: w, error: wError } = await supabase.from("profiles").select("id,full_name,email,role,is_active,created_at").order("full_name");
    if (wError) notify("Could not refresh workers: " + wError.message, "error");
    else workers = w || [];
    const { data: pu, error: puError } = await supabase.from("inventory_purchases").select("*, products(name,unit_type), profiles:purchased_by(full_name)").gte("purchased_at", dateDaysAgo(90)).lt("purchased_at", todayBounds.end).order("purchased_at", {ascending:false}).limit(1000);
    if (puError) notify("Could not refresh purchases: " + puError.message, "error");
    else purchases = pu || [];
  } else {
    workers = [];
    purchases = [];
  }
  renderDashboard();
  } finally {
    refreshInFlight = false;
    if (refreshQueued) {
      refreshQueued = false;
      queueRealtimeRefresh();
    }
  }
}
function loginView(message = "", initialMode: "choose" | "owner" | "worker" = "choose") {
  let mode: "choose" | "owner" | "worker" = initialMode;
  let signup = false;
  let recovery = passwordRecoveryMode;

  const render = (errorMessage = "") => {
    if (mode === "choose") {
      app.innerHTML = `
        <div class="login"><div class="login-card">
          <div class="brand big">${escapeHtml(settings.shop_name || "SHOP MANAGEMENT")}</div>
          <p class="muted">Choose how you are accessing this shop.</p>
          ${errorMessage ? `<div class="notice danger">${escapeHtml(errorMessage)}</div>` : ""}
          <div class="section-head"><h3>Shop Owner</h3></div>
          <div class="role-choice">
            <button id="ownerRegistered" class="primary">Already Registered</button>
            <button id="ownerNew" class="ghost">New Shop</button>
          </div>
          <div class="section-head"><h3>Worker</h3></div>
          <div class="role-choice">
            <button id="workerRegistered" class="primary">Already Registered</button>
            <button id="workerNew" class="ghost">New Worker Account</button>
          </div>
          <p class="tiny">Already Registered uses only the account email and password. New accounts use the normal shop setup flow.</p>
          <button id="demoTestBtn" class="ghost" type="button" style="margin-top:12px;border-style:dashed">🧪 Test Demo App (Temporary)</button>
        </div></div>`;
      document.querySelector("#ownerRegistered")?.addEventListener("click", () => {
        if (hasCustomerSupabaseConnection()) {
          loadSupabaseConnection();
          mode = "owner";
          render();
        } else {
          void recoverAccountView("owner");
        }
      });
      document.querySelector("#demoTestBtn")?.addEventListener("click", async () => {
        demoMode = true;
        supabase = createDemoClient() as SupabaseClient;
        await loadSession({user:{id:"demo-owner",email:"owner@demo.shop",email_confirmed_at:new Date().toISOString()}});
      });
      document.querySelector("#ownerNew")?.addEventListener("click", () => void licenseView());
      document.querySelector("#workerRegistered")?.addEventListener("click", () => {
        if (hasCustomerSupabaseConnection()) {
          loadSupabaseConnection();
          mode = "worker";
          render();
        } else {
          void recoverAccountView("worker");
        }
      });
      document.querySelector("#workerNew")?.addEventListener("click", () => void workerProjectLoginView());
      return;
    }

    app.innerHTML = `
      <div class="login"><div class="login-card">
        <div class="brand big">${escapeHtml(settings.shop_name || "SHOP MANAGEMENT")}</div>
        <p class="muted">${mode === "owner" ? "Shop owner access" : "Worker access"}</p>
        ${errorMessage ? `<div class="notice danger">${escapeHtml(errorMessage)}</div>` : ""}
        ${recovery ? `
          <div class="section-head"><h3>Reset password</h3></div>
          <form id="recoveryForm">
            <label>New password<input name="new_password" type="password" minlength="6" required></label>
            <label>Confirm new password<input name="confirm_password" type="password" minlength="6" required></label>
            <button class="primary" type="submit">Set new password</button>
          </form>
        ` : `
          ${mode === "worker" ? `<div class="notice">Enter the Shop ID given by your shop owner. After email verification, your account waits for owner approval.</div>` : `<div class="notice">The shop license is required only for the owner.</div>`}
          <div class="auth-tabs">
            <button id="showLogin" class="tab ${!signup ? "active" : ""}">Already Registered</button>
            <button id="showSignup" class="tab ${signup ? "active" : ""}">${mode === "owner" ? "New Shop" : "Create Account"}</button>
          </div>
          <form id="loginForm">
            ${signup ? `<label>Full name<input name="full_name" autocomplete="name" required></label>` : ""}
            ${mode === "worker" && signup ? `<label>Shop ID<input name="shop_id" autocomplete="organization" placeholder="Enter Shop ID" required></label>` : ""}
            <label>Email<input name="email" type="email" required autocomplete="email"></label>
            <label>Password<input name="password" type="password" required minlength="6" autocomplete="${signup ? "new-password" : "current-password"}"></label>
            <button class="primary" type="submit">${signup ? "Create account" : "Sign in"}</button>
          </form>
          <button id="backMode" type="button" class="ghost">Back</button>
          <button id="forgotPassword" type="button" class="ghost">Forgot password?</button>
          <p class="tiny">${mode === "worker" ? (signup ? "New workers enter the Shop ID once during registration. Existing workers sign in with email and password." : "Existing worker accounts use only their registered email and password.") : (signup ? "New shop owners activate their license during setup. Existing owners can sign in with their registered email and password." : "Sign in with the owner account already registered for this shop.")}</p>
        `}
      </div></div>`;

    if (recovery) {
      document.querySelector<HTMLFormElement>("#recoveryForm")?.addEventListener("submit", async e => {
        e.preventDefault();
        if (!supabase) return;
        const fd = new FormData(e.currentTarget as HTMLFormElement);
        const password = String(fd.get("new_password") || "");
        const confirm = String(fd.get("confirm_password") || "");
        if (password.length < 6) return notify("Password must be at least 6 characters.", "error");
        if (password !== confirm) return notify("Passwords do not match.", "error");
        const { error } = await supabase.auth.updateUser({ password });
        if (error) return notify(error.message, "error");
        passwordRecoveryMode = false;
        recovery = false;
        notify("Password updated successfully. Please sign in.", "success");
        await supabase.auth.signOut();
        render();
      });
      return;
    }

    document.querySelector("#showLogin")?.addEventListener("click", () => { signup = false; render(); });
    document.querySelector("#showSignup")?.addEventListener("click", () => { signup = true; render(); });
    document.querySelector("#backMode")?.addEventListener("click", () => { mode = "choose"; render(); });
    document.querySelector("#forgotPassword")?.addEventListener("click", async () => {
      if (!supabase) return;
      const email = prompt("Enter your account email:");
      if (!email?.trim()) return;
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin });
      if (error) notify(error.message, "error");
      else notify("Password reset email sent. Open the email and follow the reset link.", "success");
    });

    document.querySelector<HTMLFormElement>("#loginForm")?.addEventListener("submit", async e => {
      e.preventDefault();
      if (!supabase) return render("Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY to enable online mode.");
      const fd = new FormData(e.currentTarget as HTMLFormElement);
      const email = String(fd.get("email") || "").trim();
      const password = String(fd.get("password") || "");
      const shopId = String(fd.get("shop_id") || "").trim().toUpperCase();

      if (mode === "worker" && signup && !shopId) return render("Shop ID is required when creating a worker account.");

      if (signup) {
        const fullName = String(fd.get("full_name") || "").trim();
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            emailRedirectTo: AUTH_REDIRECT_URL,
            data: { full_name: fullName, shop_id: shopId }
          }
        });
        if (error) return render(error.message);
        await supabase.auth.signOut();
        return loginView("Account created successfully. You can now log in.", mode === "choose" ? "owner" : mode);
      }

      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) return render(error.message);
      if (data.session) {
        const { data: signedInProfile, error: signedInProfileError } = await supabase
          .from("profiles")
          .select("role,shop_id")
          .eq("id", data.session.user.id)
          .single();
        if (signedInProfileError || !signedInProfile) {
          await supabase.auth.signOut();
          return render("Could not load your account profile. Please try again.");
        }

        if (mode === "owner" && signedInProfile.role !== "owner") {
          await supabase.auth.signOut();
          return render("This account is a worker account. Use Worker access to sign in.");
        }

        let registeredShopId = String(signedInProfile.shop_id || "").trim().toUpperCase();

        if (mode === "worker") {
          if (signedInProfile.role !== "worker") {
            await supabase.auth.signOut();
            return render("This account is the shop owner account. Use Shop Owner access to sign in.");
          }
          if (!registeredShopId) {
            await supabase.auth.signOut();
            return render("This worker account has no registered Shop ID. Contact the shop owner.");
          }
          localStorage.setItem("shop_management_shop_id", registeredShopId);
        } else {
          if (signedInProfile.role !== "owner") {
            await supabase.auth.signOut();
            return render("This account is a worker account. Use Worker access to sign in.");
          }
          registeredShopId = String(localStorage.getItem("shop_management_shop_id") || "").trim().toUpperCase();
          if (!registeredShopId) {
            await supabase.auth.signOut();
            return render("This owner account is connected to a shop that is not configured on this device.");
          }
        }

        if (mode === "owner" || mode === "worker") {
          await registerAccountRecovery(email, mode, registeredShopId);
        }
        await loadSession(data.session);
      }
    });
  };
  render(message);
}


async function emailVerificationView(email: string, mode: "owner" | "worker") {
  app.innerHTML = `
    <div class="login"><div class="login-card">
      <div class="brand big">SHOP MANAGEMENT</div>
      <p class="muted">Verify your email</p>
      <div class="notice">
        <h3>Check your email</h3>
        <p>We sent a verification email to <strong>${escapeHtml(email)}</strong>.</p>
        <p>Open the email and tap <strong>Verify Email</strong>. The app will open automatically and finish your account setup.</p>
        <p class="tiny">For Android app opening, the Supabase project must allow this redirect URL:
          <strong>shopmanagement://auth-callback</strong>
          under Authentication → URL Configuration → Redirect URLs.
        </p>
        ${mode === "owner"
          ? '<p class="tiny">Your shop license is already verified, so no owner approval is required.</p>'
          : '<p class="tiny">Your Shop ID determines the shop. After email verification, the app waits for the shop owner to approve your account.</p>'}
      </div>
      <button id="resendVerification" class="ghost">Send verification email again</button>
      <button id="cancelVerification" class="ghost">Cancel</button>
    </div></div>`;
  document.querySelector("#cancelVerification")?.addEventListener("click", async () => {
    await supabase?.auth.signOut();
    loginView("", mode);
  });
  document.querySelector("#resendVerification")?.addEventListener("click", async () => {
    const button = document.querySelector<HTMLButtonElement>("#resendVerification");
    if (button) { button.disabled = true; button.textContent = "Sending..."; }
    const { error } = await supabase!.auth.resend({
      type: "signup",
      email,
      options: { emailRedirectTo: AUTH_REDIRECT_URL }
    });
    if (button) { button.disabled = false; button.textContent = "Send verification email again"; }
    if (error) notify(error.message, "error");
    else notify("Verification email sent again.", "success");
  });
}

function metric(label: string, value: string, cls = "") {
  return `<div class="metric"><div class="metric-label">${label}</div><div class="metric-value ${cls}">${value}</div></div>`;
}

function renderDashboard() {
  if (!profile) return;
  const activeSales = todaySales.filter(s => !s.voided);
  const salesTotal = activeSales.reduce((a,s) => a + Number(s.total_sale || 0), 0);
  const profit = activeSales.reduce((a,s) => a + Number(s.gross_profit || 0), 0);
  const cash = activeSales.reduce((a,s) => a + Number(s.cash_amount ?? (s.payment_mode === "cash" ? s.total_sale : 0)), 0);
  const upi = activeSales.reduce((a,s) => a + Number(s.upi_amount ?? (s.payment_mode === "upi" ? s.total_sale : 0)), 0);
  const difference = (cash + upi) - salesTotal;
  const low = products.filter(p => Number(p.current_stock_base || 0) <= Number(p.low_stock_threshold_base || 0));

  const ownerTabs = profile!.role === "owner" ? `
    <button data-tab="workers" class="tab">Workers</button>
    <button data-tab="reports" class="tab">Reports</button>
    <button data-tab="audit" class="tab">Audit</button>
    <button data-tab="settings" class="tab">Settings</button>` : "";

  rootShell(profile!.role === "owner" ? "Owner Dashboard" : "Worker Dashboard", `
    ${profile!.role === "owner" ? `
      <div class="notice"><b>Business day:</b> ${escapeHtml(localDate())} · Dashboard resets daily at ${escapeHtml(dashboardResetLabel())} (${escapeHtml(settings.timezone || "Asia/Kolkata")}).</div>
      <section class="hero-grid">
        ${metric("Current Day Sales", money(salesTotal))}
        ${metric("Current Day Profit", money(profit), profit >= 0 ? "positive" : "negative")}
        ${metric("Cash", money(cash))}
        ${metric("UPI", money(upi))}
        ${metric("Reconciliation", reconciliation(difference), difference === 0 ? "positive" : "negative")}
        ${metric("Products", String(products.length))}
        ${metric("Low Stock", String(low.length), low.length ? "negative" : "positive")}
      </section>
    ` : ""}

    <nav class="tabs">
      <button data-tab="dashboard" class="tab ${profile!.role === "owner" ? "active" : ""}">Dashboard</button>
      <button data-tab="sale" class="tab ${profile!.role === "worker" ? "active" : ""}">Add Sale</button>
      ${profile!.role === "worker" ? `<button data-tab="cart" class="tab">🛒 Cart</button>` : ""}
      <button data-tab="creditors" class="tab">Creditors</button>
      ${profile!.role === "owner" ? '<button data-tab="summary" class="tab">Daily Summary</button>' : ""}
      <button data-tab="stock" class="tab">Stock</button>
      ${profile!.role === "owner" ? `
        <button data-tab="dayend" class="tab">Day-end Summary</button>
        <button data-tab="closing" class="tab">Daily Closing</button>
        <button data-tab="history" class="tab">History</button>
      ` : ""}
      ${ownerTabs}
    </nav>

    <section id="panel-dashboard" class="panel ${profile!.role === "worker" ? "hidden" : ""}">
      ${profile!.role === "owner" ? `
        <div class="section-head"><h2>Current stock</h2><button id="refreshBtn" class="ghost">Refresh</button></div>
        <div class="table-wrap"><table><thead><tr><th>Product</th><th>Unit</th><th>Stock</th><th>Purchase</th><th>Selling</th><th>Status</th></tr></thead><tbody>
          ${products.map(p => `<tr><td>${escapeHtml(p.name)}</td><td>${p.unit_type}</td><td>${qty(Number(p.current_stock_base), p.unit_type)}</td><td>${money(Number(p.purchase_price_per_base_unit))}</td><td>${money(Number(p.selling_price_per_base_unit))}</td><td>${Number(p.current_stock_base) <= Number(p.low_stock_threshold_base) ? '<span class="badge warn">LOW</span>' : '<span class="badge ok">OK</span>'}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">No products yet.</td></tr>'}
        </tbody></table></div>
        ${low.length ? `<div class="notice warning"><b>Low stock:</b> ${low.map(p => escapeHtml(p.name)).join(", ")}</div>` : ""}
      ` : `
        <div class="worker-dashboard">
          <div class="notice"><b>Business day:</b> ${escapeHtml(localDate())} · Resets daily at ${escapeHtml(dashboardResetLabel())} (${escapeHtml(settings.timezone || "Asia/Kolkata")}).</div>
          <section class="hero-grid">
            ${metric("Today's Transactions", String(activeSales.length))}
            ${metric("Products", String(products.length))}
            ${metric("Low Stock", String(low.length), low.length ? "negative" : "positive")}
          </section>
        </div>
      `}
    </section>

    <section id="panel-sale" class="panel ${profile!.role === "worker" ? "sale-panel" : "panel hidden sale-panel"}">
      <div class="sale-heading"><div><h2>New Sale</h2><p class="muted">Find a product, enter quantity, collect payment.</p></div><span class="badge ok">SELL</span></div>
      <label class="product-search-label">Find product<input id="saleProductSearch" type="search" inputmode="search" autocomplete="off" placeholder="Search by product name..." /></label>
      <div id="saleProductGrid" class="sale-product-grid">
        ${products.map((p,i) => '<button type="button" class="sale-product-card '+(profile!.role === "worker" && i >= 2 ? "default-hidden" : "")+'" data-id="'+p.id+'"><strong>'+escapeHtml(p.name)+'</strong><span>'+qty(Number(p.current_stock_base), p.unit_type)+' available</span><b>'+money(Number(p.selling_price_per_base_unit))+'</b></button>').join("") || '<div class="notice">No products available.</div>'}
      </div>
      <form id="saleForm" class="form-grid">
        <label>Selected product<select name="product_id" required>${products.map(p => '<option value="'+p.id+'">'+escapeHtml(p.name)+' — '+qty(Number(p.current_stock_base), p.unit_type)+'</option>').join("")}</select></label>
        <label>Quantity<input name="amount" type="number" min="0.001" step="0.001" inputmode="decimal" required placeholder="Select a product first"></label>
        <label>Sold in<select name="sold_unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label>
        <label>Selling price per piece/kg<input name="price" type="number" min="0" step="0.01" inputmode="decimal" required ${profile!.role === "worker" && settings.workers_can_modify_selling_price !== true ? "readonly" : ""}></label>
        <label>Payment<select name="payment_mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label>
        <label id="singleCreditorWrap" class="hidden">Creditor<select name="creditor_id"><option value="">Select creditor</option>${creditors.map(x => `<option value="${x.id}">${escapeHtml(x.name)} — ${escapeHtml(x.mobile)}</option>`).join("")}</select><button id="newSingleCreditorBtn" type="button" class="ghost">+ New Creditor</button></label>
        <label id="cashPaymentWrap" class="hidden">Cash amount<input name="cash_amount" type="number" min="0" step="0.01" inputmode="decimal" value="0"></label>
        <label id="upiPaymentWrap" class="hidden">UPI amount<input name="upi_amount" type="number" min="0" step="0.01" inputmode="decimal" value="0"></label>
        <label id="creditPaymentWrap" class="hidden">Credit amount<input name="credit_amount" type="number" min="0" step="0.01" inputmode="decimal" value="0"></label>
        <div class="full sale-total-card"><div id="saleTotalPreview" class="notice">Select a product and enter quantity.</div></div>
        <div class="full"><button class="primary sale-submit" type="submit">Complete Sale</button></div>
      </form>
    </section>
    <section id="panel-cart" class="panel hidden">${cartCreditFeature.renderCartPanel()}</section>
    <section id="panel-creditors" class="panel hidden">${cartCreditFeature.renderCreditorsPanel()}</section>
    ${profile!.role === "owner" ? `<section id="panel-summary" class="panel hidden">${cartCreditFeature.renderDailySummaryPanel()}</section>` : ""}

    <section id="panel-dayend" class="panel hidden">
      ${renderDayEndPanel()}
    </section>

    <section id="panel-closing" class="panel hidden">
      ${renderClosingPanel()}
    </section>

    <section id="panel-history" class="panel hidden">
      ${renderHistoryPanel()}
    </section>
    <section id="panel-stock" class="panel hidden">
      ${renderStockPanel()}
    </section>

    ${profile!.role === "owner" ? `
    <section id="panel-workers" class="panel hidden">
      ${renderWorkersPanel()}
    </section>
    <section id="panel-reports" class="panel hidden">
      ${renderReportsPanel()}
    </section>
    <section id="panel-audit" class="panel hidden">
      ${renderAuditPanel()}
    </section>
    <section id="panel-settings" class="panel hidden">
      ${renderSettingsPanel()}
    </section>` : ""}
  `);

  document.querySelector("#refreshAppBtn")?.addEventListener("click", async () => {
    const button = document.querySelector<HTMLButtonElement>("#refreshAppBtn");
    if (button) { button.disabled = true; button.textContent = "Refreshing..."; }
    try { await refresh(); notify("Dashboard synced.", "success"); }
    finally { if (button) { button.disabled = false; button.textContent = "↻ Refresh"; } }
  });

  document.querySelector("#logoutBtn")?.addEventListener("click", async () => {
    await supabase?.auth.signOut();
    profile = null;
    loginView();
  });
  document.querySelector("#refreshBtn")?.addEventListener("click", refresh);

  document.querySelectorAll<HTMLButtonElement>(".tab").forEach(b => b.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(x => x.classList.remove("active"));
    document.querySelectorAll(".panel").forEach(x => x.classList.add("hidden"));
    b.classList.add("active");
    document.querySelector("#panel-" + b.dataset.tab)?.classList.remove("hidden");
    if (b.dataset.tab === "reports") renderReportsData();
  }));

  bindSaleForm();
  cartCreditFeature.bindCart();
  cartCreditFeature.bindCreditors();
  document.querySelector("#downloadDailySummaryBtn")?.addEventListener("click", () => void cartCreditFeature.downloadDailySummary());
  bindClosing();
  bindDayEnd();
  bindOwnerStock();
  bindWorkers();
  bindHistoryActions();
  bindSettings();
}

function renderDayEndPanel() {
  const today = localDate();
  const scopeSales = todaySales.filter(s => !s.voided && (profile?.role === "owner" || s.worker_id === profile?.id));
  const revenue = scopeSales.reduce((a,s) => a + Number(s.total_sale || 0), 0);
  const profit = scopeSales.reduce((a,s) => a + Number(s.gross_profit || 0), 0);
  const cash = scopeSales.reduce((a,s) => a + Number(s.cash_amount ?? (s.payment_mode === "cash" ? s.total_sale : 0)), 0);
  const upi = scopeSales.reduce((a,s) => a + Number(s.upi_amount ?? (s.payment_mode === "upi" ? s.total_sale : 0)), 0);
  const byProduct = new Map<string,{qty:number,unit:ProductUnit,revenue:number,profit:number}>();
  scopeSales.forEach(s => {
    const name = s.products?.name || s.product_name_snapshot || "Deleted product";
    const unit = (s.products?.unit_type || "piece") as ProductUnit;
    const row = byProduct.get(name) || {qty:0,unit,revenue:0,profit:0};
    row.qty += Number(s.quantity_base || 0);
    row.revenue += Number(s.total_sale || 0);
    row.profit += Number(s.gross_profit || 0);
    byProduct.set(name,row);
  });
  const byWorker = new Map<string,{sales:number,revenue:number,profit:number,cash:number,upi:number}>();
  scopeSales.forEach(s => {
    const name = s.profiles?.full_name || "Worker";
    const row = byWorker.get(name) || {sales:0,revenue:0,profit:0,cash:0,upi:0};
    row.sales += 1;
    row.revenue += Number(s.total_sale || 0);
    row.profit += Number(s.gross_profit || 0);
    row.cash += Number(s.cash_amount ?? (s.payment_mode === "cash" ? s.total_sale : 0));
    row.upi += Number(s.upi_amount ?? (s.payment_mode === "upi" ? s.total_sale : 0));
    byWorker.set(name,row);
  });
  return `
    <div class="section-head"><h2>Day-end Summary</h2><span class="badge">Automatic · ${today}</span></div>
    <p class="muted">This summary is created automatically from every sale recorded today. No worker data entry or owner confirmation is required.</p>
    <section class="hero-grid">
      ${metric("Total Sales", money(revenue))}
      ${metric("Profit", money(profit), profit >= 0 ? "positive" : "negative")}
      ${metric("Transactions", String(scopeSales.length))}
      ${metric("Cash Received", money(cash))}
      ${metric("UPI Received", money(upi))}
      ${metric("Reconciliation", reconciliation(cash + upi - revenue), Math.abs((cash + upi) - revenue) < 0.01 ? "positive" : "negative")}
    </section>
    <h3 class="subhead">Items sold</h3>
    <div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty sold</th><th>Revenue</th><th>Profit</th></tr></thead><tbody>
      ${[...byProduct.entries()].map(([name,v]) => `<tr><td>${escapeHtml(name)}</td><td>${productQtyFromBase(v.qty,v.unit)}</td><td>${money(v.revenue)}</td><td>${money(v.profit)}</td></tr>`).join("") || '<tr><td colspan="4" class="muted">No sales recorded today.</td></tr>'}
    </tbody></table></div>
    ${profile?.role === "owner" ? `
      <h3 class="subhead">Worker summary</h3>
      <div class="table-wrap"><table><thead><tr><th>Worker</th><th>Transactions</th><th>Revenue</th><th>Profit</th><th>Cash</th><th>UPI</th></tr></thead><tbody>
        ${[...byWorker.entries()].map(([name,v]) => `<tr><td>${escapeHtml(name)}</td><td>${v.sales}</td><td>${money(v.revenue)}</td><td>${money(v.profit)}</td><td>${money(v.cash)}</td><td>${money(v.upi)}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">No worker sales today.</td></tr>'}
      </tbody></table></div>
    ` : ""}
  `;
}

function renderClosingPanel() {
  const today = localDate();
  const scopeSales = todaySales.filter(s => !s.voided && (profile?.role === "owner" || s.worker_id === profile?.id));
  const revenue = scopeSales.reduce((a,s) => a + Number(s.total_sale || 0), 0);
  const profit = scopeSales.reduce((a,s) => a + Number(s.gross_profit || 0), 0);
  const cash = scopeSales.reduce((a,s) => a + Number(s.cash_amount ?? (s.payment_mode === "cash" ? s.total_sale : 0)), 0);
  const upi = scopeSales.reduce((a,s) => a + Number(s.upi_amount ?? (s.payment_mode === "upi" ? s.total_sale : 0)), 0);
  const difference = (cash + upi) - revenue;
  const byWorker = new Map<string,{sales:number,revenue:number,profit:number,cash:number,upi:number}>();
  scopeSales.forEach(s => {
    const name = s.profiles?.full_name || "Worker";
    const row = byWorker.get(name) || {sales:0,revenue:0,profit:0,cash:0,upi:0};
    row.sales += 1; row.revenue += Number(s.total_sale || 0); row.profit += Number(s.gross_profit || 0);
    row.cash += Number(s.cash_amount ?? (s.payment_mode === "cash" ? s.total_sale : 0));
    row.upi += Number(s.upi_amount ?? (s.payment_mode === "upi" ? s.total_sale : 0));
    byWorker.set(name,row);
  });
  return `
    <div class="section-head"><h2>Daily Closing</h2><span class="badge">Automatic · ${today}</span></div>
    <p class="muted">Daily closing is calculated automatically from all recorded sales. Cash and UPI are counted from the actual payment recorded on each sale.</p>
    <section class="hero-grid">
      ${metric("Total Sale", money(revenue))}
      ${metric("Profit", money(profit), profit >= 0 ? "positive" : "negative")}
      ${metric("Transactions", String(scopeSales.length))}
      ${metric("Cash Received", money(cash))}
      ${metric("UPI Received", money(upi))}
      ${metric("Reconciliation", reconciliation(difference), Math.abs(difference) < 0.01 ? "positive" : "negative")}
    </section>
    <div class="notice ${Math.abs(difference) < 0.01 ? "success" : "warning"}">
      <b>Closing total:</b> Sale ${money(revenue)} = Cash ${money(cash)} + UPI ${money(upi)}.
      ${Math.abs(difference) < 0.01 ? "All recorded payment amounts are reconciled." : "There is a payment difference that needs review."}
    </div>
    <h3 class="subhead">Today's item summary</h3>
    <div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty sold</th><th>Revenue</th><th>Profit</th></tr></thead><tbody>
      ${(() => {
        const m=new Map<string,{qty:number,unit:ProductUnit,revenue:number,profit:number}>();
        scopeSales.forEach(s=>{const n=s.products?.name||s.product_name_snapshot||"Deleted product";const u=(s.products?.unit_type||"piece") as ProductUnit;const v=m.get(n)||{qty:0,unit:u,revenue:0,profit:0};v.qty+=Number(s.quantity_base||0);v.revenue+=Number(s.total_sale||0);v.profit+=Number(s.gross_profit||0);m.set(n,v);});
        return [...m.entries()].map(([n,v])=>`<tr><td>${escapeHtml(n)}</td><td>${productQtyFromBase(v.qty,v.unit)}</td><td>${money(v.revenue)}</td><td>${money(v.profit)}</td></tr>`).join("") || '<tr><td colspan="4" class="muted">No sales recorded today.</td></tr>';
      })()}
    </tbody></table></div>
    ${profile?.role === "owner" ? `
      <h3 class="subhead">All workers</h3>
      <div class="table-wrap"><table><thead><tr><th>Worker</th><th>Sales</th><th>Revenue</th><th>Profit</th><th>Cash</th><th>UPI</th></tr></thead><tbody>
        ${[...byWorker.entries()].map(([name,v])=>`<tr><td>${escapeHtml(name)}</td><td>${v.sales}</td><td>${money(v.revenue)}</td><td>${money(v.profit)}</td><td>${money(v.cash)}</td><td>${money(v.upi)}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">No sales recorded today.</td></tr>'}
      </tbody></table></div>
    ` : ""}
  `;
}

function renderStockPanel() {
  const owner = profile?.role === "owner";
  const purchaseMap = new Map<string, number>();
  purchases.forEach(x => purchaseMap.set(x.product_id,(purchaseMap.get(x.product_id)||0)+Number(x.quantity_base||0)));
  const soldMap = new Map<string, number>();
  historySales.filter(s=>!s.voided).forEach(x => soldMap.set(x.product_id,(soldMap.get(x.product_id)||0)+Number(x.quantity_base||0)));

  return `
    <div class="section-head"><h2>Products, Stock & Activity</h2><div class="section-actions"><span class="muted">Search products and act directly</span>${owner ? '<button id="newProductBtn" class="primary">+ Add New Product</button>' : ""}</div></div>
    <div class="search-row"><input id="productSearch" type="search" placeholder="Search product by name..."><span class="tiny">${owner ? "Search, sell, edit and purchase directly from this list." : "Search any product and tap Sell to record the sale directly."}</span></div>
    <div class="table-wrap"><table id="productList"><thead><tr><th>Product</th><th>Unit</th><th>Current stock</th><th>Sold (90d)</th>${owner ? "<th>Purchased (90d)</th><th>Purchase price</th>" : ""}<th>Selling price</th><th>Actions</th></tr></thead><tbody>
    ${products.map(p=>`<tr class="product-row" data-product-name="${escapeHtml(p.name).toLowerCase()}">
      <td><b>${escapeHtml(p.name)}</b></td>
      <td>${p.unit_type}</td>
      <td>${qty(Number(p.current_stock_base),p.unit_type)}</td>
      <td>${productQtyFromBase(soldMap.get(p.id)||0,p.unit_type)}</td>
      ${owner ? `<td>${productQtyFromBase(purchaseMap.get(p.id)||0,p.unit_type)}</td><td>${money(Number(p.purchase_price_per_base_unit))}</td>` : ""}
      <td>${money(Number(p.selling_price_per_base_unit))}</td>
      <td>${owner ? `<button class="smallbtn quick-sale" data-id="${p.id}">Sell</button> <button class="smallbtn edit-product" data-id="${p.id}">Edit</button> <button class="smallbtn add-stock" data-id="${p.id}">Purchase</button> <button class="smallbtn delete-product" data-id="${p.id}">Delete</button>` : `<button class="smallbtn quick-sale" data-id="${p.id}">Sell</button>`}</td>
    </tr>`).join("") || `<tr><td colspan="${owner ? 8 : 6}" class="muted">No products.</td></tr>`}
    </tbody></table></div>    ${owner ? `
      <div id="stockModal"></div>
      <h3 class="subhead">Recent purchases</h3>
      <div class="table-wrap"><table><thead><tr><th>Date</th><th>Product</th><th>Qty</th><th>Price</th><th>Total</th><th>By</th></tr></thead><tbody>
      ${purchases.slice(0,50).map(p=>`<tr><td>${formatDateTime(p.purchased_at)}</td><td>${escapeHtml(p.products?.name||p.product_name_snapshot||"Deleted product")}</td><td>${Number(p.quantity_display)} ${escapeHtml(p.purchase_unit)}</td><td>${money(Number(p.purchase_price_per_base_unit))}</td><td>${money(Number(p.total_cost))}</td><td>${escapeHtml(p.profiles?.full_name||"")}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">No purchases yet.</td></tr>'}
      </tbody></table></div>` : ''}
  `;
}
function renderWorkersPanel() {
  const pending = workers.filter(w => !w.is_active);
  const active = workers.filter(w => w.is_active);
  return `
    <div class="section-head"><h2>Worker Requests</h2><span class="badge ${pending.length ? "warn" : "ok"}">${pending.length} pending</span></div>
    <div class="notice">New accounts are inactive until approved. Approving a request gives the worker access; their app checks automatically and opens without a manual refresh.</div>
    <div class="table-wrap"><table><thead><tr><th>Name</th><th>Email</th><th>Requested</th><th>Action</th></tr></thead><tbody>
      ${pending.map(w=>`<tr><td>${escapeHtml(w.full_name || "Unnamed")}</td><td>${escapeHtml(w.email)}</td><td>${new Date(w.created_at).toLocaleString()}</td><td><button class="smallbtn approve-worker" data-id="${w.id}">Approve</button></td></tr>`).join("") || '<tr><td colspan="4" class="muted">No pending requests.</td></tr>'}
    </tbody></table></div>
    <div class="section-head"><h2>Active Accounts</h2><span class="muted">Owner can manage active worker accounts.</span></div>
    <div class="table-wrap"><table><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Active</th><th>Created</th><th>Action</th></tr></thead><tbody>
      ${active.map(w=>`<tr><td><input class="worker-name" data-id="${w.id}" value="${escapeHtml(w.full_name)}"></td><td>${escapeHtml(w.email)}</td><td><select class="worker-role" data-id="${w.id}"><option value="worker" ${w.role==="worker"?"selected":""}>Worker</option><option value="owner" ${w.role==="owner"?"selected":""}>Owner</option></select></td><td><input class="worker-active" data-id="${w.id}" type="checkbox" checked></td><td>${new Date(w.created_at).toLocaleDateString()}</td><td><button class="smallbtn remove-worker" data-id="${w.id}">Remove</button></td></tr>`).join("") || '<tr><td colspan="6" class="muted">No active accounts yet.</td></tr>'}
    </tbody></table></div>
    <div class="notice">The database protects the last active owner from being disabled.</div>
  `;
}


function renderReportsPanel() {
  return `
    <div class="section-head"><h2>Reports</h2><div class="report-actions"><button class="smallbtn report-range" data-days="1">Daily</button><button class="smallbtn report-range" data-days="7">Weekly</button><button class="smallbtn report-range" data-days="30">Monthly</button><button class="smallbtn report-range" data-days="90">90 Days</button></div></div>
    <div id="reportData" class="report-grid"><div class="metric"><div class="metric-label">Loading</div><div class="metric-value">…</div></div></div>
    <div id="reportExtra"></div>
    <div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty</th><th>Revenue</th><th>Profit</th></tr></thead><tbody id="reportRows"></tbody></table></div>
  `;
}

function renderAuditPanel() {
  return `
    <div class="section-head"><h2>Audit Trail</h2><span class="muted">Important changes are kept instead of silently overwritten.</span></div>
    <div class="table-wrap"><table><thead><tr><th>Time</th><th>User</th><th>Action</th><th>Entity</th><th>Details</th></tr></thead><tbody>
    ${auditLogs.map(a=>`<tr><td>${formatDateTime(a.created_at)}</td><td>${escapeHtml(a.profiles?.full_name || a.profiles?.email || a.actor_id || "System")}</td><td><span class="badge">${escapeHtml(a.action)}</span></td><td>${escapeHtml(a.entity_type)}</td><td>${escapeHtml(auditDescription(a))}</td></tr>`).join("") || '<tr><td colspan="5" class="muted">No audit events.</td></tr>'}
    </tbody></table></div>
  `;
}

function renderSettingsPanel() {
  return `
    <h2>Settings</h2>
    <form id="settingsForm" class="form-grid">
      <label>Shop name<input name="shop_name" value="${escapeHtml(settings.shop_name)}" required></label>
      <label>Shop ID<input value="${escapeHtml(settings.shop_id || localStorage.getItem("shop_management_shop_id") || "Not configured")}" readonly></label><button id="shopIdCopy" type="button" class="ghost">Copy Shop ID</button>
    <div class="modal-card full">
      <h3>Supabase Project</h3>
      <p class="tiny">This shop uses the owner's Supabase project. You can verify the current database or replace the project.</p>
      <div class="section-head">
        <span class="badge ok">${escapeHtml((localStorage.getItem(SUPABASE_CONFIG_URL_KEY) || "Not connected"))}</span>
        <span class="muted">${supabase ? "Connected" : "Not connected"}</span>
      </div>
      <div class="form-grid">
        <button id="verifySupabaseBtn" type="button" class="ghost">Verify Database</button>
        <button id="downloadSqlSettingsBtn" type="button" class="ghost">Download SQL</button>
        <button id="changeSupabaseBtn" type="button" class="primary">Change Supabase Project</button>
      </div>
    </div>
      <label>Currency<input name="currency" value="${escapeHtml(settings.currency)}" maxlength="8" required></label>
      <label>Timezone<input name="timezone" value="${escapeHtml(settings.timezone)}" required></label>
      <label>Dashboard reset time
        <div class="form-grid">
          <select name="dashboard_reset_hour" aria-label="Reset hour">
            ${[1,2,3,4,5,6,7,8,9,10,11,12].map(h => `<option value="${h}" ${(Number(String(settings.dashboard_reset_time || "00:00").split(":")[0]) % 12 || 12) === h ? "selected" : ""}>${h}</option>`).join("")}
          </select>
          <select name="dashboard_reset_minute" aria-label="Reset minute">
            ${Array.from({length:60},(_,m)=>`<option value="${String(m).padStart(2,"0")}" ${String(settings.dashboard_reset_time || "00:00").split(":")[1] === String(m).padStart(2,"0") ? "selected" : ""}>${String(m).padStart(2,"0")}</option>`).join("")}
          </select>
          <select name="dashboard_reset_period" aria-label="Reset AM or PM">
            <option value="AM" ${Number(String(settings.dashboard_reset_time || "00:00").split(":")[0]) < 12 ? "selected" : ""}>AM</option>
            <option value="PM" ${Number(String(settings.dashboard_reset_time || "00:00").split(":")[0]) >= 12 ? "selected" : ""}>PM</option>
          </select>
        </div>
        <span class="tiny">12-hour format with AM/PM</span>
      </label>
      <label><input type="checkbox" name="allow_below_cost_sales" ${settings.allow_below_cost_sales !== false ? "checked" : ""}> Allow sales below purchase cost</label>
      <label><input type="checkbox" name="allow_zero_price_sales" ${settings.allow_zero_price_sales !== false ? "checked" : ""}> Allow zero-price/free sales</label>
      <label><input type="checkbox" name="workers_can_modify_selling_price" ${settings.workers_can_modify_selling_price === true ? "checked" : ""}> Workers can modify selling price</label>
      <div class="full"><button class="primary" type="submit">Save settings</button></div>
    </form>
    <div class="notice">Keep the timezone aligned with the shop's business day so daily closing/report dates remain consistent.</div>
    <div class="section-head subhead"><h3>Backup / Export</h3><button id="exportBtn" class="primary">Export shop data (JSON)</button></div>
    <p class="tiny">Exports the records available to the owner in the browser. No service-role key is exposed.</p>
    <div class="section-head subhead"><h3>Shop Report</h3><button id="downloadAllReportBtn" class="ghost" type="button">Download All Report</button></div>
    <p class="tiny">Downloads only the current stock, last 90 days daily sales/profit, and outstanding creditors. The report is generated on this device and is never uploaded to Supabase Storage.</p>
    <div class="modal-card">
      <h3>Start over</h3>
      <p class="tiny">Owner only. Clears sales, purchases, daily closings, day-end entries and their historical audit entries, then resets every product's current stock to 0. A permanent audit record of this Clear All action remains. Products, users and shop settings are kept.</p>
      <button id="clearAllBtn" class="ghost">Clear all transaction data</button>
    </div>
  `;
}

function renderHistoryPanel() {
  return `
    <h2>History</h2>
    <h3 class="subhead">Sales — last 90 days</h3>
    <div class="table-wrap"><table><thead><tr><th>Date/time</th><th>Worker</th><th>Product</th><th>Qty</th><th>Price</th><th>Payment</th>${profile?.role==="owner" ? "<th>Total</th><th>Profit</th>" : ""}<th>Status</th><th></th></tr></thead><tbody>
    ${historySales.map(s=>{
      const payment = s.payment_mode==="split"
        ? "CASH " + money(Number(s.cash_amount||0)) + " + UPI " + money(Number(s.upi_amount||0))
        : String(s.payment_mode || "cash").toUpperCase();
      return `<tr class="${s.voided?"muted":""}"><td>${formatDateTime(s.sold_at)}</td><td>${escapeHtml(s.profiles?.full_name||"")}</td><td>${escapeHtml(s.products?.name||s.product_name_snapshot||"Deleted product")}</td><td>${saleQty(s)}</td><td>${money(Number(s.selling_price_per_base_unit))}</td><td>${escapeHtml(payment)}</td>${profile?.role==="owner" ? `<td>${money(Number(s.total_sale))}</td><td>${money(Number(s.gross_profit))}</td>` : ""}<td>${s.voided?"VOIDED":"ACTIVE"}</td><td>${profile?.role==="owner"&&!s.voided?`<button class="smallbtn void-sale" data-id="${s.id}">Correct</button>`:""}</td></tr>`;
    }).join("") || `<tr><td colspan="${profile?.role==="owner" ? 10 : 8}" class="muted">No sales history.</td></tr>`}
    </tbody></table></div>
        <h3 class="subhead">Daily closings</h3>
    <div class="table-wrap"><table><thead><tr><th>Date</th><th>Worker</th><th>Expected</th><th>Cash</th><th>UPI</th><th>Difference</th><th>Status</th></tr></thead><tbody>
    ${closings.map(c=>`<tr><td>${c.business_date}</td><td>${escapeHtml(c.profiles?.full_name||"")}</td><td>${money(Number(c.expected_total))}</td><td>${money(Number(c.cash_amount))}</td><td>${money(Number(c.upi_amount))}</td><td class="${Number(c.difference)===0?"positive":"negative"}">${money(Number(c.difference))}</td><td>${escapeHtml(c.status)}</td></tr>`).join("") || '<tr><td colspan="7" class="muted">No closings yet.</td></tr>'}
    </tbody></table></div>
    <h3 class="subhead">Day-end summaries</h3>
    <div class="table-wrap"><table><thead><tr><th>Date</th><th>Worker</th><th>Expected</th><th>Cash</th><th>UPI</th><th>Status</th><th>Submitted</th><th>Items</th></tr></thead><tbody>
    ${dayEnds.map(d => {
      const lines = dayEndLines.filter(l => l.summary_id === d.id);
      const items = lines.map(l => String(l.products?.name || l.product_name_snapshot || "Deleted product") + " " + Number(l.quantity_display) + " " + (l.products?.unit_type === "weight" ? (l.sold_unit === "kg" ? "kg" : "g") : "pcs")).join(", ");
      return "<tr><td>" + d.business_date + "</td><td>" + escapeHtml(d.profiles?.full_name || "") + "</td><td>" + money(Number(d.expected_total || 0)) + "</td><td>" + money(Number(d.cash_amount || 0)) + "</td><td>" + money(Number(d.upi_amount || 0)) + "</td><td>" + escapeHtml(d.status) + "</td><td>" + (d.submitted_at ? formatDateTime(d.submitted_at) : "—") + "</td><td>" + escapeHtml(items || "—") + "</td></tr>";
    }).join("") || '<tr><td colspan="8" class="muted">No day-end summaries yet.</td></tr>'}
    </tbody></table></div>
  `;
}

function renderClosing() { return renderClosingPanel(); }


function bindSaleForm() {
  const form = document.querySelector<HTMLFormElement>("#saleForm");
  if (!form || !supabase || !profile) return;
  const search = document.querySelector<HTMLInputElement>("#saleProductSearch");
  const cards = [...document.querySelectorAll<HTMLButtonElement>(".sale-product-card")];
  search?.addEventListener("input", () => {
    const q = String(search.value || "").trim().toLowerCase();
    cards.forEach((card, index) => {
      const matches = String(card.textContent).toLowerCase().includes(q);
      const hideForWorkerDefault = profile!.role === "worker" && !q && index >= 2;
      card.classList.toggle("hidden", !matches || hideForWorkerDefault);
    });
  });
  const select = form.elements.namedItem("product_id") as HTMLSelectElement;
  const markSelected = () => cards.forEach(card => card.classList.toggle("selected", card.dataset.id === select.value));
  cards.forEach(card => card.addEventListener("click", () => { select.value = card.dataset.id || ""; select.dispatchEvent(new Event("change")); markSelected(); document.querySelector<HTMLInputElement>('#saleForm input[name="amount"]')?.focus(); }));
  const amount = form.elements.namedItem("amount") as HTMLInputElement;
  const unit = form.elements.namedItem("sold_unit") as HTMLSelectElement;
  const price = form.elements.namedItem("price") as HTMLInputElement;
  const paymentMode = form.elements.namedItem("payment_mode") as HTMLSelectElement;
  const cashAmount = form.elements.namedItem("cash_amount") as HTMLInputElement;
  const upiAmount = form.elements.namedItem("upi_amount") as HTMLInputElement;
  const creditAmount = form.elements.namedItem("credit_amount") as HTMLInputElement;
  const cashWrap = document.querySelector<HTMLElement>("#cashPaymentWrap");
  const upiWrap = document.querySelector<HTMLElement>("#upiPaymentWrap");
  const creditWrap = document.querySelector<HTMLElement>("#creditPaymentWrap");
  const creditorWrap = document.querySelector<HTMLElement>("#singleCreditorWrap");
  const creditorSelect = form.elements.namedItem("creditor_id") as HTMLSelectElement;
  const preview = document.querySelector<HTMLElement>("#saleTotalPreview");

  const totalPreview = () => {
    const raw = Number(amount.value);
    const pricePerBase = Number(price.value);
    const p = products.find(x => x.id === select.value);
    if (!p || !Number.isFinite(raw) || raw <= 0 || !Number.isFinite(pricePerBase) || pricePerBase < 0) return 0;
    return p.unit_type === "piece"
      ? raw * pricePerBase
      : ((String(unit.value) === "kg" ? raw : raw / 1000) * pricePerBase);
  };

  const updatePaymentUI = () => {
    const split = paymentMode.value === "split";
    const credit = paymentMode.value === "credit" || paymentMode.value === "credit_split";
    const creditSplit = paymentMode.value === "credit_split";
    cashWrap?.classList.toggle("hidden", !split && !creditSplit);
    creditorWrap?.classList.toggle("hidden", !credit);
    upiWrap?.classList.toggle("hidden", !split && !creditSplit);
    creditWrap?.classList.toggle("hidden", !creditSplit);
    if (!split && !creditSplit) {
      cashAmount.value = paymentMode.value === "cash" ? totalPreview().toFixed(2) : "0";
      upiAmount.value = paymentMode.value === "upi" ? totalPreview().toFixed(2) : "0";
      creditAmount.value = "0";
    }
    if (creditSplit && creditAmount.value === "") creditAmount.value = "0";
  };

  const update = () => {
    const p = products.find(x => x.id === select.value);
    if (!p) return;
    price.value = String(Number(p.selling_price_per_base_unit));
    price.readOnly = profile!.role === "worker" && settings.workers_can_modify_selling_price !== true;
    if (p.unit_type === "weight") {
      unit.disabled = false;
      unit.innerHTML = '<option value="grams">grams</option><option value="kg">kg</option>';
      unit.value = "grams";
      amount.min = "0.001";
      amount.step = "0.001";
      amount.placeholder = "e.g. 250, 500, 750 grams";
    } else {
      unit.disabled = true;
      unit.innerHTML = '<option value="piece">pieces</option>';
      unit.value = "piece";
      amount.min = "1";
      amount.step = "1";
      amount.placeholder = "e.g. 1, 2, 3 pieces";
    }
    updatePaymentUI();
    if (preview) preview.textContent = "Sale total: " + money(totalPreview());
  };

  [amount, price, unit].forEach(el => el.addEventListener("input", () => {
    updatePaymentUI();
    if (preview) preview.textContent = "Sale total: " + money(totalPreview());
  }));
  paymentMode.addEventListener("change", updatePaymentUI);
  document.querySelector("#newSingleCreditorBtn")?.addEventListener("click", async () => {
    const name = prompt("Creditor name:");
    const mobile = prompt("Mobile number:");
    if (!name?.trim() || !mobile?.trim()) return;
    const { error } = await supabase!.rpc("get_or_create_creditor", { p_name: name.trim(), p_mobile: mobile.trim() });
    if (error) notify(error.message, "error"); else { notify("Creditor added.", "success"); await refresh(); }
  });
  select.addEventListener("change", update);
  update();

  form.addEventListener("submit", async e => {
    e.preventDefault();
    const fd = new FormData(form);
    const p = products.find(x => x.id === fd.get("product_id"));
    if (!p) return;
    const raw = Number(fd.get("amount"));
    // Always send the canonical database unit. The visible "pieces" label is
    // only display text; the RPC expects the value "piece".
    const soldUnit = p.unit_type === "piece" ? "piece" : String(fd.get("sold_unit"));
    const base = p.unit_type === "piece" ? raw : soldUnit === "kg" ? raw * 1000 : raw;
    const pricePerBase = Number(fd.get("price"));
    const mode = String(fd.get("payment_mode"));
    const total = totalPreview();
    let cash = Number(fd.get("cash_amount"));
    let upi = Number(fd.get("upi_amount"));
    let credit = Number(fd.get("credit_amount"));

    if (!Number.isFinite(raw) || raw <= 0 || !Number.isFinite(base) || base <= 0 || base > Number(p.current_stock_base)) {
      return notify("Invalid quantity or insufficient stock.", "error");
    }
    if (p.unit_type === "piece" && !Number.isInteger(raw)) {
      return notify("Piece products must be sold as a whole number of pieces.", "error");
    }
    if (!Number.isFinite(pricePerBase) || pricePerBase < 0) return notify("Enter a valid selling price.", "error");
    if (!["cash", "upi", "split", "credit", "credit_split"].includes(mode)) return notify("Choose a valid payment mode.", "error");
    if (mode === "cash") { cash = total; upi = 0; }
    if (mode === "upi") { cash = 0; upi = total; }
    if (mode === "credit") { cash = 0; upi = 0; credit = total; if (!creditorSelect.value) return notify("Select a creditor.", "error"); }
    if (mode === "credit_split" && !creditorSelect.value) return notify("Select a creditor.", "error");
    if (mode === "credit_split") { if (!creditorSelect.value) return notify("Select a creditor.", "error"); if (!Number.isFinite(cash) || !Number.isFinite(upi) || !Number.isFinite(credit) || cash < 0 || upi < 0 || credit <= 0) return notify("Enter valid Cash, UPI and Credit amounts.", "error"); if (Math.abs((cash + upi + credit) - total) > 0.01) return notify("Cash + UPI + Credit must equal the sale total of " + money(total) + ".", "error"); }
    if (mode === "split" && (!Number.isFinite(cash) || !Number.isFinite(upi) || cash < 0 || upi < 0)) {
      return notify("Enter valid Cash and UPI amounts.", "error");
    }
    if (mode !== "credit" && mode !== "credit_split" && Math.abs((cash + upi) - total) > 0.01) {
      return notify("Cash + UPI must equal the sale total of " + money(total) + ".", "error");
    }

    if (mode === "credit" || mode === "credit_split") {
      const { error } = await supabase!.rpc("complete_cart_sale", {
        p_worker_id: profile!.id,
        p_items: [{ product_id: p.id, quantity_base: base, quantity_display: raw, sold_unit: soldUnit, selling_price_per_base_unit: pricePerBase }],
        p_payment_mode: mode, p_cash_amount: cash, p_upi_amount: upi, p_credit_amount: credit, p_creditor_id: creditorSelect.value
      });
      if (error) notify(error.message, "error");
      else { notify("Credit sale recorded", "success"); form.reset(); await refresh(); }
      return;
    }

    const { error } = await supabase!.rpc("record_sale", {
      p_product_id: p.id,
      p_worker_id: profile!.id,
      p_quantity_base: base,
      p_quantity_display: raw,
      p_sold_unit: soldUnit,
      p_selling_price_per_base_unit: pricePerBase,
      p_payment_mode: mode,
      p_cash_amount: cash,
      p_upi_amount: upi
    });
    if (error) notify(error.message, "error");
    else {
      notify("Sale recorded", "success");
      form.reset();
      await refresh();
    }
  });
}

function bindClosing() {
  // Daily Closing is now a live, read-only aggregate of recorded sales.
  // No duplicate worker cash/UPI entry is required.
}

function bindDayEnd() {
  // Day-end Summary is automatically derived from today's recorded sales.
}

function bindOwnerStock() {
  const search = document.querySelector<HTMLInputElement>("#productSearch");
  search?.addEventListener("input", () => {
    const q = search.value.trim().toLowerCase();
    document.querySelectorAll<HTMLElement>(".product-row").forEach(row => {
      row.style.display = (row.dataset.productName || "").includes(q) ? "" : "none";
    });
  });
  document.querySelectorAll<HTMLButtonElement>(".quick-sale").forEach(b => b.addEventListener("click", () => {
    const saleTab = document.querySelector<HTMLButtonElement>('[data-tab="sale"]');
    const saleSelect = document.querySelector<HTMLSelectElement>('#saleForm select[name="product_id"]');
    if (saleSelect) saleSelect.value = b.dataset.id || "";
    document.querySelectorAll(".tab").forEach(x => x.classList.remove("active"));
    document.querySelectorAll(".panel").forEach(x => x.classList.add("hidden"));
    saleTab?.classList.add("active");
    document.querySelector("#panel-sale")?.classList.remove("hidden");
    saleSelect?.dispatchEvent(new Event("change"));
    document.querySelector<HTMLInputElement>('#saleForm input[name="amount"]')?.focus();
  }));

  document.querySelector("#newProductBtn")?.addEventListener("click", () => {
    const holder = document.querySelector<HTMLDivElement>("#stockModal")!;
    holder.innerHTML = `<div class="modal-card"><h3>Add product</h3><form id="productForm" class="form-grid">
      <label>Name<input name="name" required></label>
      <label>Unit<select name="unit"><option value="piece">Pieces</option><option value="weight">Weight (kg/g)</option></select></label>
      <label>Opening stock<input name="stock" type="number" min="0" step="0.001" required></label>
      <label>Purchase price per piece/kg<input name="buy" type="number" min="0" step="0.01" required></label>
      <label>Selling price per piece/kg<input name="sell" type="number" min="0" step="0.01" required></label>
      <label>Low-stock threshold<input name="low" type="number" min="0" step="0.001" value="1" required></label>
      <div class="full"><button class="primary">Create product</button><button type="button" id="cancelProduct" class="ghost">Cancel</button></div>
    </form></div>`;
    document.querySelector("#cancelProduct")?.addEventListener("click", () => holder.innerHTML = "");
    document.querySelector<HTMLFormElement>("#productForm")!.addEventListener("submit", async e => {
      e.preventDefault(); const fd = new FormData(e.currentTarget as HTMLFormElement);
      const unit = String(fd.get("unit")) as ProductUnit; const display = Number(fd.get("stock")); const base = unit === "weight" ? display * 1000 : display;
      const { error } = await supabase!.rpc("create_product", {
        p_name: String(fd.get("name")), p_unit_type: unit, p_opening_stock_base: base,
        p_purchase_price: Number(fd.get("buy")), p_selling_price: Number(fd.get("sell")),
        p_low_stock_threshold_base: unit === "weight" ? Number(fd.get("low")) * 1000 : Number(fd.get("low"))
      });
      if (error) notify(error.message, "error");
      else { holder.innerHTML = ""; notify("Product added", "success"); await refresh(); }
    });
  });

  document.querySelectorAll<HTMLButtonElement>(".edit-product").forEach(b => b.addEventListener("click", async () => {
    const p = products.find(x => x.id === b.dataset.id); if (!p) return;
    const name = prompt("Product name:", p.name); if (name === null || !name.trim()) return;
    const buy = Number(prompt("Purchase price per piece/kg:", String(p.purchase_price_per_base_unit)));
    const sell = Number(prompt("Selling price per piece/kg:", String(p.selling_price_per_base_unit)));
    const low = Number(prompt("Low-stock threshold in " + (p.unit_type === "weight" ? "kg" : "pieces") + ":", String(p.unit_type === "weight" ? Number(p.low_stock_threshold_base) / 1000 : p.low_stock_threshold_base)));
    if (!Number.isFinite(buy) || buy < 0 || !Number.isFinite(sell) || sell < 0 || !Number.isFinite(low) || low < 0) return notify("Invalid product values", "error");
    const { error } = await supabase!.from("products").update({
      name: name.trim(), purchase_price_per_base_unit: buy, selling_price_per_base_unit: sell,
      low_stock_threshold_base: p.unit_type === "weight" ? low * 1000 : low, updated_at: new Date().toISOString()
    }).eq("id", p.id);
    if (error) notify(error.message, "error");
    else { notify("Product updated", "success"); await refresh(); }
  }));

  document.querySelectorAll<HTMLButtonElement>(".add-stock").forEach(b => b.addEventListener("click", async () => {
    const p = products.find(x => x.id === b.dataset.id); if (!p) return;
    const display = Number(prompt(`Add stock for ${p.name} in ${p.unit_type === "weight" ? "kg" : "pieces"}:`));
    if (!Number.isFinite(display) || display <= 0) return;
    const unit = p.unit_type === "weight" ? "kg" : "piece";
    const base = p.unit_type === "weight" ? display * 1000 : display;
    const price = Number(prompt("Purchase price per piece/kg:", String(p.purchase_price_per_base_unit)));
    if (!Number.isFinite(price) || price < 0) return;
    const { error } = await supabase!.rpc("add_inventory_purchase", { p_product_id: p.id, p_quantity_base: base, p_quantity_display: display, p_purchase_unit: unit, p_purchase_price: price });
    if (error) notify(error.message, "error");
    else { notify("Stock added", "success"); await refresh(); }
  }));

  document.querySelectorAll<HTMLButtonElement>(".delete-product").forEach(b => b.addEventListener("click", async () => {
    const p = products.find(x => x.id === b.dataset.id); if (!p) return;
    const stock = qty(Number(p.current_stock_base), p.unit_type);
    const ok = confirm(`Permanently delete "${p.name}"? Current stock: ${stock}. Existing sales and purchase history will be kept with their recorded product name. A new product with the same name can be created afterward.`);
    if (!ok) return;
    const { error } = await supabase!.rpc("delete_product", { p_product_id: p.id });
    if (error) notify(error.message, "error");
    else { notify("Product permanently deleted", "success"); await refresh(); }
  }));
}

function bindWorkers() {
  document.querySelectorAll<HTMLButtonElement>(".remove-worker").forEach(b => b.addEventListener("click", async () => {
    const id = b.dataset.id;
    if (!id) return;
    const worker = workers.find(w => String(w.id) === String(id));
    if (!worker || worker.role !== "worker") return notify("Only worker accounts can be removed here.", "error");
    if (!confirm("Remove " + (worker.full_name || worker.email || "this worker") + " from the shop? Their sales and audit history will be kept.")) return;
    b.disabled = true;
    await saveWorker(id, { is_active: false });
  }));

  document.querySelectorAll<HTMLButtonElement>(".approve-worker").forEach(b => b.addEventListener("click", async () => {
    const id = b.dataset.id;
    if (!id) return;
    b.disabled = true;
    await saveWorker(id, { role: "worker", is_active: true });
  }));
  document.querySelectorAll<HTMLInputElement>(".worker-name").forEach(i => i.addEventListener("change", () => saveWorker(i.dataset.id!, { full_name: i.value })));
  document.querySelectorAll<HTMLSelectElement>(".worker-role").forEach(i => i.addEventListener("change", () => saveWorker(i.dataset.id!, { role: i.value })));
  document.querySelectorAll<HTMLInputElement>(".worker-active").forEach(i => i.addEventListener("change", () => saveWorker(i.dataset.id!, { is_active: i.checked })));
}

async function saveWorker(id: string, patch: any) {
  if (!supabase) return;
  if (id === profile?.id && ("role" in patch || "is_active" in patch)) return notify("Protect your current owner account from accidental lockout.", "error");
  const { error } = await supabase.from("profiles").update(patch).eq("id", id);
  if (error) notify(error.message, "error");
  else { notify("Worker updated", "success"); await refresh(); }
}


function bindHistoryActions() {
  document.querySelectorAll<HTMLButtonElement>(".void-sale").forEach(b => b.addEventListener("click", async () => {
    const reason = prompt("Correction reason (required):");
    if (!reason?.trim()) return;
    const { error } = await supabase!.rpc("void_sale", { p_sale_id: b.dataset.id, p_reason: reason.trim() });
    if (error) notify(error.message, "error");
    else { notify("Sale corrected; stock restored", "success"); await refresh(); }
  }));
}

async function loadAudit() {
  if (!supabase || profile?.role !== "owner") { auditLogs = []; return; }
  const { data, error } = await supabase.from("audit_logs").select("*, profiles:actor_id(full_name,email)").order("created_at", { ascending: false }).limit(200);
  if (error) notify("Could not refresh audit trail: " + error.message, "error");
  else auditLogs = data || [];
}

async function renderReportsData(days=1) {
  const holder=document.querySelector<HTMLDivElement>("#reportData");
  const extra=document.querySelector<HTMLDivElement>("#reportExtra");
  const rows=document.querySelector<HTMLTableSectionElement>("#reportRows");
  if(!holder||!rows||!supabase) return;
  const periodStartDate=shiftBusinessDate(localDate(),-(days-1));
  const periodBounds=businessDayBounds(localDate());
  const sinceIso=businessDayBounds(periodStartDate).start;
  const untilIso=periodBounds.end;
  const {data:sales,error}=await supabase.from("sales").select("*, products(name,unit_type), profiles:worker_id(full_name)").gte("sold_at",sinceIso).lt("sold_at",untilIso).order("sold_at",{ascending:false}).limit(2000);
  if(error) return notify(error.message,"error");
  const active=(sales||[]).filter(s=>!s.voided);
  const revenue=active.reduce((a,s)=>a+Number(s.total_sale||0),0);
  const profit=active.reduce((a,s)=>a+Number(s.gross_profit||0),0);
  const transactionCount=active.length;
  const grouped=new Map<string,{qty:number,unit:ProductUnit,revenue:number,profit:number}>();
  const workerMap=new Map<string,{id:string,name:string,sales:number,revenue:number,profit:number,cash:number,upi:number}>();
  active.forEach(s=>{
    const name=s.products?.name||s.product_name_snapshot||"Deleted product";
    const unit=(s.products?.unit_type||"piece") as ProductUnit;
    const v=grouped.get(name)||{qty:0,unit,revenue:0,profit:0};
    v.qty+=Number(s.quantity_base||0); v.revenue+=Number(s.total_sale||0); v.profit+=Number(s.gross_profit||0); grouped.set(name,v);
    const id=String(s.worker_id||"unknown");
    const worker=s.profiles?.full_name||"Unknown";
    const w=workerMap.get(id)||{id,name:worker,sales:0,revenue:0,profit:0,cash:0,upi:0};
    w.sales+=1; w.revenue+=Number(s.total_sale||0); w.profit+=Number(s.gross_profit||0);
    w.cash+=Number(s.cash_amount ?? (s.payment_mode==="cash" ? s.total_sale : 0));
    w.upi+=Number(s.upi_amount ?? (s.payment_mode==="upi" ? s.total_sale : 0));
    workerMap.set(id,w);
  });
  const cash=active.reduce((a,s)=>a+Number(s.cash_amount ?? (s.payment_mode==="cash" ? s.total_sale : 0)),0);
  const upi=active.reduce((a,s)=>a+Number(s.upi_amount ?? (s.payment_mode==="upi" ? s.total_sale : 0)),0);
  const purchaseCost=purchases.filter(p=>p.purchased_at>=sinceIso && p.purchased_at<untilIso).reduce((a,p)=>a+Number(p.total_cost||0),0);
  holder.innerHTML=[metric("Revenue",money(revenue)),metric("Profit",money(profit),profit>=0?"positive":"negative"),metric("Sales transactions",String(transactionCount)),metric("Purchases",money(purchaseCost)),metric("Cash",money(cash)),metric("UPI",money(upi)),metric("Reconciliation",reconciliation(cash+upi-revenue),Math.abs(cash+upi-revenue)<0.01?"positive":"negative")].join("");
  rows.innerHTML=[...grouped.entries()].sort((a,b)=>b[1].qty-a[1].qty).map(([name,v])=>"<tr><td>"+escapeHtml(name)+"</td><td>"+productQtyFromBase(v.qty,v.unit)+"</td><td>"+money(v.revenue)+"</td><td>"+money(v.profit)+"</td></tr>").join("") || '<tr><td colspan="4" class="muted">No sales for this period.</td></tr>';
  if(extra){
    const label=days===1?"Current business day":days===7?"Last 7 business days":days===30?"Last 30 business days":"Last 90 business days";
    const workerOptions = new Map<string,string>();
    workers.filter(w=>w.role==="worker").forEach(w=>workerOptions.set(String(w.id),String(w.full_name||w.email||"Worker")));
    workerMap.forEach(w=>workerOptions.set(w.id,w.name));
    const options=[...workerOptions.entries()].sort((a,b)=>a[1].localeCompare(b[1])).map(([id,name])=>"<option value=\""+id+"\">"+escapeHtml(name)+"</option>").join("");
    extra.innerHTML="<div class=\"section-head\"><h3>Worker-wise sales</h3><span class=\"muted\">"+label+"</span></div><div class=\"form-grid\"><label>Worker<select id=\"workerSalesSelect\"><option value=\"all\">All workers</option>"+options+"</select></label></div><div id=\"workerSalesDetails\"></div>";
    const workerSelect=document.querySelector<HTMLSelectElement>("#workerSalesSelect");
    const workerDetails=document.querySelector<HTMLDivElement>("#workerSalesDetails");
    const renderWorkerSales=(workerId:string)=>{
      if(!workerDetails) return;
      const selected=workerId==="all" ? active : active.filter(s=>String(s.worker_id||"unknown")===workerId);
      const selectedRevenue=selected.reduce((a,s)=>a+Number(s.total_sale||0),0);
      const selectedProfit=selected.reduce((a,s)=>a+Number(s.gross_profit||0),0);
      const selectedCash=selected.reduce((a,s)=>a+Number(s.cash_amount ?? (s.payment_mode==="cash" ? s.total_sale : 0)),0);
      const selectedUpi=selected.reduce((a,s)=>a+Number(s.upi_amount ?? (s.payment_mode==="upi" ? s.total_sale : 0)),0);
      const productMap=new Map<string,{qty:number,unit:ProductUnit,revenue:number,profit:number}>();
      selected.forEach(s=>{
        const name=s.products?.name||s.product_name_snapshot||"Deleted product"; const unit=(s.products?.unit_type||"piece") as ProductUnit;
        const v=productMap.get(name)||{qty:0,unit,revenue:0,profit:0};
        v.qty+=Number(s.quantity_base||0); v.revenue+=Number(s.total_sale||0); v.profit+=Number(s.gross_profit||0); productMap.set(name,v);
      });
      const productRows=[...productMap.entries()].map(([name,v])=>"<tr><td>"+escapeHtml(name)+"</td><td>"+productQtyFromBase(v.qty,v.unit)+"</td><td>"+money(v.revenue)+"</td><td>"+money(v.profit)+"</td></tr>").join("") || '<tr><td colspan="4" class="muted">No sales for this worker.</td></tr>';
      const saleRows=selected.map(s=>{
        const payment=s.payment_mode==="split" ? "Cash "+money(Number(s.cash_amount||0))+" + UPI "+money(Number(s.upi_amount||0)) : String(s.payment_mode||"cash").toUpperCase()+" "+money(Number(s.total_sale||0));
        return "<tr><td>"+formatDateTime(s.sold_at)+"</td><td>"+escapeHtml(s.products?.name||s.product_name_snapshot||"Deleted product")+"</td><td>"+saleQty(s)+"</td><td>"+money(Number(s.selling_price_per_base_unit||0))+"</td><td>"+escapeHtml(payment)+"</td><td>"+money(Number(s.total_sale||0))+"</td><td>"+money(Number(s.gross_profit||0))+"</td></tr>";
      }).join("") || '<tr><td colspan="7" class="muted">No sales for this worker.</td></tr>';
      workerDetails.innerHTML="<div class=\"report-grid\">"+metric("Transactions",String(selected.length))+metric("Revenue",money(selectedRevenue))+metric("Profit",money(selectedProfit),selectedProfit>=0?"positive":"negative")+metric("Cash",money(selectedCash))+metric("UPI",money(selectedUpi))+metric("Reconciliation",reconciliation(selectedCash+selectedUpi-selectedRevenue),Math.abs(selectedCash+selectedUpi-selectedRevenue)<0.01?"positive":"negative")+"</div>"
        +"<h4 class=\"subhead\">Product summary</h4><div class=\"table-wrap\"><table><thead><tr><th>Product</th><th>Qty sold</th><th>Revenue</th><th>Profit</th></tr></thead><tbody>"+productRows+"</tbody></table></div>"
        +"<h4 class=\"subhead\">Individual sales</h4><div class=\"table-wrap\"><table><thead><tr><th>Time</th><th>Product</th><th>Qty</th><th>Price</th><th>Payment</th><th>Total</th><th>Profit</th></tr></thead><tbody>"+saleRows+"</tbody></table></div>";
    };
    const dailyWorkerMap=new Map<string,{date:string;worker:string;transactions:number;revenue:number;profit:number;cash:number;upi:number}>();
    active.forEach(s=>{
      const date=new Intl.DateTimeFormat("en-CA",{timeZone:settings.timezone}).format(new Date(s.sold_at));
      const wid=String(s.worker_id||"unknown");
      const key=date+"|"+wid;
      const row=dailyWorkerMap.get(key)||{date,worker:String(s.profiles?.full_name||s.worker_id||"Unknown"),transactions:0,revenue:0,profit:0,cash:0,upi:0};
      row.transactions++; row.revenue+=Number(s.total_sale||0); row.profit+=Number(s.gross_profit||0);
      row.cash+=Number(s.cash_amount ?? (s.payment_mode==="cash" ? s.total_sale : 0));
      row.upi+=Number(s.upi_amount ?? (s.payment_mode==="upi" ? s.total_sale : 0));
      dailyWorkerMap.set(key,row);
    });
    const dailyRows=[...dailyWorkerMap.values()].sort((a,b)=>b.date.localeCompare(a.date)||a.worker.localeCompare(b.worker)).map(v=>"<tr><td>"+escapeHtml(v.date)+"</td><td>"+escapeHtml(v.worker)+"</td><td>"+v.transactions+"</td><td>"+money(v.revenue)+"</td><td>"+money(v.profit)+"</td><td>"+money(v.cash)+"</td><td>"+money(v.upi)+"</td></tr>").join("") || '<tr><td colspan="7" class="muted">No worker-day activity in this period.</td></tr>';
    extra.insertAdjacentHTML("beforeend","<h4 class=\"subhead\">Worker daily history</h4><div class=\"table-wrap\"><table><thead><tr><th>Date</th><th>Worker</th><th>Transactions</th><th>Revenue</th><th>Profit</th><th>Cash</th><th>UPI</th></tr></thead><tbody>"+dailyRows+"</tbody></table></div>");
    workerSelect?.addEventListener("change",()=>renderWorkerSales(workerSelect.value));
    renderWorkerSales(workerSelect?.value||"all");

    const daily90Start=businessDayBounds(shiftBusinessDate(localDate(),-89)).start;
    const daily90End=businessDayBounds().end;
    const daily90Result=days===90 ? {data:active} : await supabase.from("sales").select("*, profiles:worker_id(full_name)").gte("sold_at",daily90Start).lt("sold_at",daily90End).order("sold_at",{ascending:false}).limit(5000);
    const daily90Sales=(daily90Result.data||[]).filter((s:any)=>!s.voided);
    const dailyMap=new Map<string,{revenue:number;profit:number;cash:number;upi:number;transactions:number}>();
    daily90Sales.forEach((s:any)=>{
      const d=new Intl.DateTimeFormat("en-CA",{timeZone:settings.timezone||"Asia/Kolkata"}).format(new Date(s.sold_at));
      const v=dailyMap.get(d)||{revenue:0,profit:0,cash:0,upi:0,transactions:0};
      v.revenue+=Number(s.total_sale||0); v.profit+=Number(s.gross_profit||0); v.transactions++;
      v.cash+=Number(s.cash_amount ?? (s.payment_mode==="cash"?s.total_sale:0));
      v.upi+=Number(s.upi_amount ?? (s.payment_mode==="upi"?s.total_sale:0));
      dailyMap.set(d,v);
    });
    const daily90Rows:string[]=[];
    for(let i=0;i<90;i++){
      const d=shiftBusinessDate(localDate(),-i);
      const v=dailyMap.get(d)||{revenue:0,profit:0,cash:0,upi:0,transactions:0};
      daily90Rows.push("<tr><td>"+d+"</td><td>"+v.transactions+"</td><td>"+money(v.revenue)+"</td><td>"+money(v.profit)+"</td><td>"+money(v.cash)+"</td><td>"+money(v.upi)+"</td><td>"+reconciliation(v.cash+v.upi-v.revenue)+"</td></tr>");
    }
    extra.insertAdjacentHTML("beforeend","<h4 class=\"subhead\">90-day daily sales & profit history</h4><div class=\"table-wrap\"><table><thead><tr><th>Business date</th><th>Transactions</th><th>Revenue</th><th>Profit</th><th>Cash</th><th>UPI</th><th>Reconciliation</th></tr></thead><tbody>"+daily90Rows.join("")+"</tbody></table></div>");
  }
  document.querySelectorAll<HTMLButtonElement>(".report-range").forEach(b=>b.onclick=()=>renderReportsData(Number(b.dataset.days)));
}
async function exportShopData() {
  if(!supabase||profile?.role!=="owner") return;
  const [p,pu,s,c,d,l,w,st,pr,ad]=await Promise.all([
    supabase.from("products").select("*"), supabase.from("inventory_purchases").select("*"), supabase.from("sales").select("*"),
    supabase.from("daily_closings").select("*"), supabase.from("day_end_summaries").select("*"), supabase.from("day_end_summary_lines").select("*"),
    supabase.from("audit_logs").select("*"), supabase.from("shop_settings").select("*"), supabase.from("profiles").select("*"), supabase.from("automatic_day_end_snapshots").select("*")
  ]);
  const cr=await supabase.from("creditors").select("*");
  const cl=await supabase.from("credit_ledger").select("*");
  const tx=await supabase.from("sale_transactions").select("*");
  const newTableResults=[cr,cl,tx].filter(x=>x.error && !String(x.error.message).toLowerCase().includes("could not find the table") && !String(x.error.message).toLowerCase().includes("relation"));
  const results=[p,pu,s,c,d,l,w,st,pr,ad,...newTableResults];
  const failed=results.find(x=>x.error);
  if(failed?.error) return notify("Backup failed: " + failed.error.message,"error");
  const payload={exported_at:new Date().toISOString(),products:p.data||[],purchases:pu.data||[],sales:s.data||[],daily_closings:c.data||[],day_end_summaries:d.data||[],day_end_summary_lines:l.data||[],audit_logs:w.data||[],settings:st.data||[],profiles:pr.data||[],automatic_day_end_snapshots:ad.data||[],creditors:cr.data||[],credit_ledger:cl.data||[],sale_transactions:tx.data||[]};
  const blob=new Blob([JSON.stringify(payload,null,2)],{type:"application/json"});
  const url=URL.createObjectURL(blob); const a=document.createElement("a"); a.href=url; a.download="shop-backup-"+localDate()+".json"; a.click(); URL.revokeObjectURL(url);
  notify("Backup export created","success");
}


async function downloadAllShopReport() {
  if (!supabase || profile?.role !== "owner") return;

  const button = document.querySelector<HTMLButtonElement>("#downloadAllReportBtn");
  if (button) {
    button.disabled = true;
    button.textContent = "Generating...";
  }

  try {
    const tz = String(settings.timezone || "Asia/Kolkata");
    const end = businessDayBounds().end;
    const start = businessDayBounds(shiftBusinessDate(localDate(), -89)).start;

    // Fetch the three report datasets only. No database writes are performed.
    const { data: stockRows, error: stockError } = await supabase
      .from("products")
      .select("name,unit_type,current_stock_base,purchase_price_per_base_unit,selling_price_per_base_unit,is_active")
      .eq("is_active", true)
      .order("name");

    if (stockError) throw new Error("Could not load stock: " + stockError.message);

    const salesRows: any[] = [];
    const pageSize = 1000;
    for (let from = 0; ; from += pageSize) {
      const { data, error } = await supabase
        .from("sales")
        .select("sold_at,total_sale,gross_profit,cash_amount,upi_amount,voided")
        .gte("sold_at", start)
        .lt("sold_at", end)
        .order("sold_at", { ascending: true })
        .range(from, from + pageSize - 1);

      if (error) throw new Error("Could not load 90-day sales: " + error.message);
      const rows = data || [];
      salesRows.push(...rows);
      if (rows.length < pageSize) break;
    }

    const { data: creditorRows, error: creditorError } = await supabase
      .from("creditors")
      .select("id,name,mobile,is_active")
      .eq("is_active", true)
      .order("name");

    if (creditorError) throw new Error("Could not load creditors: " + creditorError.message);

    const ledgerRows: any[] = [];
    for (let from = 0; ; from += pageSize) {
      const { data, error } = await supabase
        .from("credit_ledger")
        .select("creditor_id,type,amount")
        .range(from, from + pageSize - 1);

      if (error) throw new Error("Could not load credit balances: " + error.message);
      const rows = data || [];
      ledgerRows.push(...rows);
      if (rows.length < pageSize) break;
    }

    const daily = new Map<string, { revenue:number; profit:number; cash:number; upi:number }>();
    for (let i = 0; i < 90; i++) {
      daily.set(shiftBusinessDate(localDate(), -i), { revenue:0, profit:0, cash:0, upi:0 });
    }

    for (const sale of salesRows) {
      if (sale.voided) continue;
      const date = new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date(sale.sold_at));
      const row = daily.get(date);
      if (!row) continue;
      row.revenue += Number(sale.total_sale || 0);
      row.profit += Number(sale.gross_profit || 0);
      row.cash += Number(sale.cash_amount || 0);
      row.upi += Number(sale.upi_amount || 0);
    }

    const balances = new Map<string, number>();
    for (const entry of ledgerRows) {
      const amount = Number(entry.amount || 0);
      const previous = balances.get(String(entry.creditor_id)) || 0;
      balances.set(
        String(entry.creditor_id),
        previous + (entry.type === "credit_sale" ? amount : entry.type === "payment_received" ? -amount : amount)
      );
    }

    const clean = (value: unknown) => String(value ?? "").replace(/[\r\n|]/g, " ").trim();
    const moneyPlain = (value: number) => {
      const currency = String(settings.currency || "INR");
      return currency + " " + value.toFixed(2);
    };
    const qtyText = (p: any) => {
      const base = Number(p.current_stock_base || 0);
      return p.unit_type === "weight"
        ? (base / 1000).toFixed(3).replace(/\.?0+$/, "") + " kg"
        : base.toFixed(0) + " pcs";
    };
    const fixed = (value: string, width: number) => value.length > width ? value.slice(0, Math.max(0, width - 1)) + "…" : value.padEnd(width, " ");

    const lines: string[] = [];
    lines.push("SHOP MANAGEMENT — SIMPLE OWNER REPORT");
    lines.push("Generated: " + new Date().toLocaleString());
    lines.push("");
    lines.push("1. CURRENT STOCK");
    lines.push(fixed("NO.", 6) + fixed("ITEM", 28) + fixed("STOCK", 16) + fixed("PURCHASE PRICE", 18) + "SALE PRICE");
    lines.push("-".repeat(86));

    (stockRows || []).forEach((p:any, index:number) => {
      lines.push(
        fixed(String(index + 1), 6) +
        fixed(clean(p.name), 28) +
        fixed(qtyText(p), 16) +
        fixed(moneyPlain(Number(p.purchase_price_per_base_unit || 0)), 18) +
        moneyPlain(Number(p.selling_price_per_base_unit || 0))
      );
    });
    if (!(stockRows || []).length) lines.push("No active products.");

    lines.push("");
    lines.push("2. DAILY SALES — LAST 90 DAYS");
    lines.push(fixed("DATE", 14) + fixed("TOTAL SALE", 18) + fixed("PROFIT", 18) + fixed("CASH", 18) + "UPI");
    lines.push("-".repeat(86));

    for (let i = 0; i < 90; i++) {
      const date = shiftBusinessDate(localDate(), -i);
      const row = daily.get(date) || { revenue:0, profit:0, cash:0, upi:0 };
      lines.push(
        fixed(date, 14) +
        fixed(moneyPlain(row.revenue), 18) +
        fixed(moneyPlain(row.profit), 18) +
        fixed(moneyPlain(row.cash), 18) +
        moneyPlain(row.upi)
      );
    }

    lines.push("");
    lines.push("3. CREDITORS — OUTSTANDING");
    lines.push(fixed("CREDITOR", 32) + fixed("MOBILE", 18) + "AMOUNT DUE");
    lines.push("-".repeat(70));

    let creditorCount = 0;
    (creditorRows || []).forEach((creditor:any) => {
      const balance = balances.get(String(creditor.id)) || 0;
      if (balance <= 0.009) return;
      creditorCount++;
      lines.push(
        fixed(clean(creditor.name), 32) +
        fixed(clean(creditor.mobile), 18) +
        moneyPlain(balance)
      );
    });
    if (!creditorCount) lines.push("No outstanding creditors.");

    lines.push("");
    lines.push("Generated locally on this device. No report file is uploaded to Supabase Storage.");

    const content = lines.join("\n");
    const fileName = "Shop_Report_" + localDate() + ".txt";

    if (Capacitor.getPlatform() === "android") {
      await ShopDownloads.saveTextToDownloads({ fileName, content });
      notify("Report saved to Android Downloads.", "success");
    } else {
      const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = fileName;
      a.click();
      URL.revokeObjectURL(url);
      notify("Report downloaded.", "success");
    }
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), "error");
  } finally {
    if (button) {
      button.disabled = false;
      button.textContent = "Download All Report";
    }
  }
}

function bindSettings() {
  document.querySelector("#verifySupabaseBtn")?.addEventListener("click", async () => {
    if (!supabase || profile?.role !== "owner") return;
    const shopId = localStorage.getItem("shop_management_shop_id") || String(settings.shop_id || "");
    const button = document.querySelector<HTMLButtonElement>("#verifySupabaseBtn");
    if (button) { button.disabled = true; button.textContent = "Verifying..."; }
    try {
      const { data, error } = await supabase.rpc("verify_shop_management", { p_expected_shop_id: shopId });
      if (error) throw new Error(error.message);
      if (!data?.ok) throw new Error("Database is not ready: " + (Array.isArray(data?.missing) ? data.missing.join(", ") : "required items missing"));
      const cartCheck = await supabase.rpc("verify_cart_credit_schema");
      if (cartCheck.error) throw new Error(cartCheck.error.message);
      if (!cartCheck.data?.ok) throw new Error("Cart/Credit database is not ready: " + (Array.isArray(cartCheck.data?.missing) ? cartCheck.data.missing.join(", ") : "required items missing"));
      notify("Database verification passed.", "success");
    } catch (err) {
      notify(err instanceof Error ? err.message : String(err), "error");
    } finally {
      if (button) { button.disabled = false; button.textContent = "Verify Database"; }
    }
  });
  document.querySelector("#downloadSqlSettingsBtn")?.addEventListener("click", () => void downloadShopSql());
  document.querySelector("#changeSupabaseBtn")?.addEventListener("click", () => {
    if (profile?.role !== "owner") return;
    supabaseConnectionView("", "owner", () => { loadSupabaseConnection(); renderDashboard(); });
  });
  document.querySelector("#exportBtn")?.addEventListener("click", exportShopData);
  document.querySelector("#downloadAllReportBtn")?.addEventListener("click", () => void downloadAllShopReport());
  document.querySelector("#shopIdCopy")?.addEventListener("click", async () => {
    const id = String(settings.shop_id || "").trim();
    if (!id) return notify("Shop ID is not configured yet.", "error");
    try { await navigator.clipboard.writeText(id); notify("Shop ID copied.", "success"); } catch { notify("Copy failed. Use the Shop ID shown in Settings.", "info"); }
  });
  document.querySelector("#clearAllBtn")?.addEventListener("click", async () => {
    if (!supabase || profile?.role !== "owner") return;
    const first = prompt("This will permanently clear all sales, purchases, closings and day-end entries, and reset all product stock to 0. Existing transaction audit history will be cleared, but a permanent audit record of this Clear All action will remain. Products, users and settings will remain. Type CLEAR to continue:");
    if (first !== "CLEAR") return notify("Clear cancelled.","info");
    const second = prompt("Final confirmation: type CLEAR ALL");
    if (second !== "CLEAR ALL") return notify("Clear cancelled.","info");
    const {error}=await supabase.rpc("clear_all_shop_data");
    if(error) notify(error.message,"error"); else { notify("All transaction data cleared. Product stock reset to 0.","success"); await refresh(); }
  });
  document.querySelector<HTMLFormElement>("#settingsForm")?.addEventListener("submit",async e=>{
    e.preventDefault(); const fd=new FormData(e.currentTarget as HTMLFormElement);
    const timezone=String(fd.get("timezone")).trim();
    try { new Intl.DateTimeFormat("en-US",{timeZone:timezone}).format(); }
    catch { return notify("Invalid IANA timezone. Example: Asia/Kolkata","error"); }
    const resetHour12 = Number(fd.get("dashboard_reset_hour") || 12);
    const resetMinute = String(fd.get("dashboard_reset_minute") || "00").padStart(2, "0");
    const resetPeriod = String(fd.get("dashboard_reset_period") || "AM");
    const resetHour24 = resetPeriod === "AM" ? (resetHour12 === 12 ? 0 : resetHour12) : (resetHour12 === 12 ? 12 : resetHour12 + 12);
    const dashboard_reset_time = String(resetHour24).padStart(2, "0") + ":" + resetMinute;
    const {error}=await supabase!.from("shop_settings").update({shop_name:String(fd.get("shop_name")),currency:String(fd.get("currency")),timezone,allow_below_cost_sales:fd.get("allow_below_cost_sales")==="on",allow_zero_price_sales:fd.get("allow_zero_price_sales")==="on",workers_can_modify_selling_price:fd.get("workers_can_modify_selling_price")==="on",dashboard_reset_time,updated_at:new Date().toISOString()}).eq("id",1);
    if(error) notify(error.message,"error"); else { notify("Settings saved","success"); await refresh(); }
  });
}

async function loadSession(session: any) {
  if (!supabase) return;
  if (!session) {
    profile = null;
    stopWorkerApprovalWatcher();
    realtimeChannel?.unsubscribe();
    realtimeChannel = null;
    return loginView();
  }

  const { data, error } = await supabase
    .from("profiles")
    .select("id,full_name,email,role,is_active")
    .eq("id", session.user.id)
    .single();

  if (error) return loginView("Your account profile could not be loaded: " + error.message);

  if (!session.user.email_confirmed_at) {
    await supabase.auth.signOut();
    return loginView("Please verify your email before signing in.", data.role === "owner" ? "owner" : "worker");
  }

  if (data.role === "owner" && !demoMode) {
    const licenseOk = await ensureShopLicense();
    if (!licenseOk) {
      await supabase.auth.signOut();
      return loginView("Owner access requires the shop license.", "owner");
    }

    if (!data.is_active) {
      const { data: activated, error: activationError } =
        await supabase.rpc("activate_user_after_email_verification");
      if (!activationError && activated?.ok) data.is_active = true;
      if (activationError) console.error("Owner email activation failed:", activationError.message);
    }
  }

  profile = data as UserProfile;
  if (demoMode) { settings = { ...settings, shop_name: "Demo Grocery Store", currency: "INR", timezone: "Asia/Kolkata", shop_id: "SHOP-DEMO0001", workers_can_modify_selling_price: true }; }
  if (!profile.full_name) profile.full_name = session.user.email?.split("@")[0] || "User";
  setupRealtime();

  if (profile.role === "worker" && !profile.is_active) {
    showWorkerPendingApproval();
    return;
  }

  if (!profile.is_active) {
    await supabase.auth.signOut();
    return loginView("Your account is not active yet.", data.role === "owner" ? "owner" : "worker");
  }

  stopWorkerApprovalWatcher();
  await refresh();
}

async function bootstrap() {
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(()=>{});
  dashboardResetTimer = setInterval(() => {
    const currentBusinessDate = localDate();
    if (currentBusinessDate !== lastBusinessDate && profile) {
      lastBusinessDate = currentBusinessDate;
      void refresh();
    }
  }, 30000);
  if (!loadSupabaseConnection()) return loginView();
  const { data: { session } } = await supabase!.auth.getSession();
  await loadSession(session);
  supabase!.auth.onAuthStateChange((event, nextSession) => {
    if (event === "SIGNED_OUT") {
      profile = null;
      realtimeChannel?.unsubscribe();
      realtimeChannel = null;
      loginView();
    } else if (event === "PASSWORD_RECOVERY") {
      passwordRecoveryMode = true;
      setTimeout(() => loginView(), 0);
    } else if ((event === "SIGNED_IN" || event === "USER_UPDATED") && nextSession && !profile) {
      setTimeout(() => loadSession(nextSession), 0);
    }
  });

  const handleAuthDeepLink = async (url: string) => {
    try {
      const parsed = new URL(url);
      const hashParams = new URLSearchParams(parsed.hash.replace(/^#/, ""));
      const queryParams = parsed.searchParams;
      const errorDescription = hashParams.get("error_description") || queryParams.get("error_description");
      const errorCode = hashParams.get("error_code") || queryParams.get("error_code");
      if (errorDescription || errorCode) {
        return loginView(errorDescription || errorCode || "Email verification failed.");
      }

      const accessToken = hashParams.get("access_token");
      const refreshToken = hashParams.get("refresh_token");
      if (accessToken && refreshToken) {
        const { data, error } = await supabase!.auth.setSession({
          access_token: accessToken,
          refresh_token: refreshToken
        });
        if (error) throw error;
        if (data.session) {
          await loadSession(data.session);
          return;
        }
      }

      const code = queryParams.get("code");
      if (code) {
        const { data, error } = await supabase!.auth.exchangeCodeForSession(code);
        if (error) throw error;
        if (data.session) {
          await loadSession(data.session);
          return;
        }
      }

      loginView("The verification link could not be completed. Please request a new verification email.", "owner");
    } catch (err) {
      console.error("Auth deep-link error:", err);
      loginView(err instanceof Error ? err.message : "Could not complete email verification.", "owner");
    }
  };

  App.addListener("appUrlOpen", ({ url }) => {
    void handleAuthDeepLink(url);
  }).catch(() => {});

  void App.getLaunchUrl().then(result => {
    if (result?.url) void handleAuthDeepLink(result.url);
  }).catch(() => {});
}
bootstrap();