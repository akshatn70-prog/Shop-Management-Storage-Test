import { createClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { Browser } from "@capacitor/browser";

const RENDER_BASE="https://shop-management-oauth.onrender.com";
const PRODUCTION_APP_URL="https://shop-management-storage-test.onrender.com";
const URL_KEY="shop_management_supabase_url";
const KEY_KEY="shop_management_supabase_publishable_key";
let busy=false;

const esc=(s:any)=>String(s??"").replace(/[&<>\"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));

function localConnection(){
  return {url:localStorage.getItem(URL_KEY)||"",key:localStorage.getItem(KEY_KEY)||""};
}
const CONFIRM_FLAG="shop_management_email_confirmed";

const APP_VERSION="1.0.0";
const UPDATE_REPO="akshatn70-prog/Shop-Management-Storage-Test";

function compareAppVersions(a:string,b:string){
  const pa=a.replace(/^v/i,"").split(".").map(x=>Number.parseInt(x,10)||0);
  const pb=b.replace(/^v/i,"").split(".").map(x=>Number.parseInt(x,10)||0);
  for(let i=0;i<3;i++){
    const av=pa[i]||0,bv=pb[i]||0;
    if(av>bv)return 1;
    if(av<bv)return -1;
  }
  return 0;
}

async function checkForAppUpdate(){
  try{
    const response=await fetch("https://api.github.com/repos/"+UPDATE_REPO+"/releases/latest",{headers:{Accept:"application/vnd.github+json"}});
    if(!response.ok)throw new Error("Could not check for the latest app release.");
    const release=await response.json();
    const latest=String(release.tag_name||"").replace(/^v/i,"");
    const apk=(Array.isArray(release.assets)?release.assets:[]).find((asset:any)=>String(asset.name||"").toLowerCase().endsWith(".apk"));
    if(!latest||!apk?.browser_download_url)throw new Error("No downloadable APK was found in the latest release.");
    if(compareAppVersions(latest,APP_VERSION)<=0){
      message("You are using the latest app version (v"+APP_VERSION+").","info");
      return;
    }
    const ok=window.confirm("A new Shop Management version is available.\n\nCurrent: v"+APP_VERSION+"\nLatest: v"+latest+"\n\nDownload the update now?");
    if(!ok)return;
    if(Capacitor.isNativePlatform()){
      try{await Browser.open({url:String(apk.browser_download_url)})}catch{window.open(String(apk.browser_download_url),"_blank","noopener,noreferrer")}
    }else{
      window.open(String(apk.browser_download_url),"_blank","noopener,noreferrer");
    }
  }catch(e){
    message(e instanceof Error?e.message:String(e),"danger");
  }
}

async function handleEmailConfirmationRedirect(){
  const c=localConnection();
  if(!c.url||!c.key)return false;

  // Supabase's default confirmation email redirects back to the production
  // website with the authenticated session in the URL hash. Process it here,
  // then let the normal app load with the confirmed session.
  const hash=window.location.hash||"";
  if(!/access_token=|type=signup|type=email|error_code=/.test(hash))return false;

  try{
    const client=createClient(c.url,c.key,{
      auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}
    });
    const sessionResult=await client.auth.getSession();
    if(sessionResult.data.session?.user){
      localStorage.setItem(CONFIRM_FLAG,String(Date.now()));
      history.replaceState({},document.title,window.location.pathname+window.location.search);
      return true;
    }
  }catch{}

  return false;
}
function show(html:string){
  const app=document.querySelector("#app");if(app)app.innerHTML='<div class="login"><div class="login-card">'+html+"</div></div>";
}
function message(text:string,type="info"){
  const n=document.createElement("div");n.className="notice "+type;n.textContent=text;
  document.querySelector(".login-card")?.prepend(n);
}
async function api(path:string,options:any={}){
  const r=await fetch(RENDER_BASE+path,{...options,headers:{"Content-Type":"application/json",...(options.headers||{})}});
  const d=await r.json().catch(()=>({}));
  if(!r.ok){
    const detail=d.detail?String(d.detail):"";
    throw new Error(detail?String(d.error||"Render setup server error")+" — "+detail:String(d.error||"Render setup server error"));
  }
  return d;
}
async function finishDirectLogin(email:string,password:string){
  const c=localConnection();
  if(!c.url||!c.key)throw new Error("This device is not registered yet. Use Register / Connect Supabase first.");
  const client=createClient(c.url,c.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
  const r=await client.auth.signInWithPassword({email,password});
  if(r.error)throw new Error(r.error.message);
  location.reload();
}
async function register(){
  if(busy)return;busy=true;
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Register Shop Owner</h2><p class="muted">Create your Shop Management owner account. Next, you will connect the Supabase account that should own this shop.</p><div class="notice">Your Shop Management email and password are separate from your Supabase Dashboard login. Your Supabase password is never entered or stored here.</div><form id="ownerReg"><label>Full name<input name="name" autocomplete="name" required></label><label>Shop Owner Email<input name="email" type="email" autocomplete="email" required></label><label>Shop Owner Password<input name="password" type="password" minlength="6" autocomplete="new-password" required></label><button class="primary wide">Connect Supabase & Register</button></form><button id="backLogin" class="ghost wide">Back to Login</button>');
  document.querySelector("#backLogin")?.addEventListener("click",()=>{busy=false;renderGate()});
  document.querySelector("#ownerReg")?.addEventListener("submit",async e=>{
    e.preventDefault();
    const fd=new FormData(e.currentTarget as HTMLFormElement),name=String(fd.get("name")||"").trim(),email=String(fd.get("email")||"").trim(),password=String(fd.get("password")||"");
    if(!name||!email||password.length<6)return message("Enter your name, email and a password of at least 6 characters.","danger");
    try{
      await new Promise<void>((resolve,reject)=>{
        show('<div class="brand big">SHOP MANAGEMENT</div><h2>Connect Supabase</h2><p class="muted">Choose the Supabase account that should own this shop.</p><div class="notice">Your Supabase email and password are entered only on Supabase. Shop Management never receives or stores your Supabase password.</div><button id="supabaseLogin" class="primary wide">I Already Have a Supabase Account</button><button id="supabaseSignup" class="ghost wide">Create a New Supabase Account</button><button id="supabaseContinue" class="ghost wide" style="display:none">I Created My Account — Continue</button><p id="supabaseHelp" class="tiny">If you do not have a Supabase account, create one first. After signing in or creating your account, continue and authorize Shop Management.</p>');
        document.querySelector("#supabaseLogin")?.addEventListener("click",()=>resolve());
        document.querySelector("#supabaseSignup")?.addEventListener("click",()=>{
          window.open("https://supabase.com/dashboard/sign-up","_blank","noopener,noreferrer");
          const b=document.querySelector("#supabaseContinue") as HTMLElement|null;
          if(b)b.style.display="block";
          const h=document.querySelector("#supabaseHelp");if(h)h.textContent="Finish creating or signing into your Supabase account in the new tab, then return here and tap “I Created My Account — Continue”.";
        });
        document.querySelector("#supabaseContinue")?.addEventListener("click",()=>resolve());
      });
      message("Starting secure Supabase authorization...");
      const start=await api("/api/oauth/start",{method:"POST",body:"{}"});
      message("Supabase opened. Sign in with the Supabase account that should own this shop, then press Allow. Your Supabase password stays on Supabase.");
      if(Capacitor.isNativePlatform()){
        try{await Browser.open({url:start.authorize_url})}catch{window.open(start.authorize_url,"_blank")}
      }else{
        window.open(start.authorize_url,"_blank","noopener,noreferrer");
      }
      let ready=null;
      for(let i=0;i<180;i++){
        await new Promise(r=>setTimeout(r,2000));
        const st=await api("/api/oauth/status?session="+encodeURIComponent(start.session_id));
        if(st.status==="ready"){ready=st;break}
      }
      if(!ready)throw new Error("Supabase authorization timed out. Start registration again.");
      const projects=ready.projects||[];
      let organizations=ready.organizations||[];
      if(!organizations.length){
        message("Loading your Supabase organizations...");
        for(let i=0;i<8 && !organizations.length;i++){
          await new Promise(r=>setTimeout(r,1200));
          const refreshed=await api("/api/oauth/status?session="+encodeURIComponent(start.session_id));
          if(refreshed.status==="ready")organizations=refreshed.organizations||[];
        }
      }
      if(!organizations.length){
        throw new Error("Your Supabase organization could not be loaded. Please start registration again and authorize Shop Management again. If you recently changed OAuth permissions, re-authorizing is required for the new scopes.");
      }
      let ref="";
      show('<div class="brand big">SHOP MANAGEMENT</div><h2>Connect your Supabase account</h2><p class="muted">You are now connected to the Supabase account you authorized. Choose where this shop should be stored.</p><div class="notice">Use the existing project you want, or create a new Supabase project in your authorized account. Shop Management never receives your Supabase password.</div>'+(projects.length?'<label>Existing project<select id="projectPick" class="wide"><option value="">Select existing project...</option>'+projects.map((p:any)=>'<option value="'+esc(p.ref)+'">'+esc(p.name)+" — "+esc(p.region||"")+'</option>').join("")+'</select></label><button id="installSelected" class="primary wide">Use Existing Project</button>':'<div class="notice">No existing Supabase projects were found in this account.</div>')+'<div style="text-align:center;margin:14px 0;color:#64748b">OR</div><button id="newProject" class="ghost wide">Create New Supabase Project</button>');
        await new Promise<void>((resolve,reject)=>{
          document.querySelector("#installSelected")?.addEventListener("click",()=>{
            const v=String((document.querySelector("#projectPick") as HTMLSelectElement).value||"");
            if(!v){message("Select an existing project, or choose Create New Supabase Project.","danger");return}
            ref=v;resolve();
          });
          document.querySelector("#newProject")?.addEventListener("click",()=>{
            const regions=["ap-southeast-1","ap-northeast-1","ap-south-1","us-east-1","us-west-1","eu-west-1"];
            show('<div class="brand big">SHOP MANAGEMENT</div><h2>Create Supabase project</h2><p class="muted">A new project will be created in your Supabase account and then Shop Management will install its database automatically.</p><label>Organization<select id="orgPick" class="wide">'+organizations.map((o:any)=>'<option value="'+esc(o.id)+'">'+esc(o.name)+'</option>').join("")+'</select></label><label>Project name<input id="newProjectName" class="wide" value="Shop Management"></label><label>Region<select id="regionPick" class="wide">'+regions.map(r=>'<option value="'+r+'"'+(r==="ap-southeast-1"?" selected":"")+'>'+r+'</option>').join("")+'</select></label><button id="createProject" class="primary wide">Create Project & Continue</button>');
            document.querySelector("#createProject")?.addEventListener("click",async()=>{
              const organization_id=String((document.querySelector("#orgPick") as HTMLSelectElement)?.value||"");
              const name=String((document.querySelector("#newProjectName") as HTMLInputElement)?.value||"").trim();
              const region=String((document.querySelector("#regionPick") as HTMLSelectElement)?.value||"ap-southeast-1");
              if(!organization_id||!name){message("Select an organization and enter a project name.","danger");return}
              try{
                message("Creating your Supabase project. This can take a few minutes...");
                const created=await api("/api/oauth/create-project",{method:"POST",body:JSON.stringify({session_id:start.session_id,organization_id,name,region})});
                ref=created.project.ref;resolve();
              }catch(e){message(e instanceof Error?e.message:String(e),"danger")}
            });
          });
        });
      show('<div class="brand big">SHOP MANAGEMENT</div><h2>Installing...</h2><p class="muted">Creating the database, security, functions and Auth settings.</p><div class="notice">Please keep this screen open.</div>');
      const installed=await api("/api/oauth/install",{method:"POST",body:JSON.stringify({session_id:start.session_id,project_ref:ref})});
      localStorage.setItem(URL_KEY,installed.url);
      localStorage.setItem(KEY_KEY,installed.key);

      // Keep normal Supabase email confirmation enabled. Supabase sends the
      // confirmation email and redirects the user to the real production site.
      const client=createClient(installed.url,installed.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
      const signUp=await client.auth.signUp({
        email,
        password,
        options:{
          data:{full_name:name},
          emailRedirectTo:PRODUCTION_APP_URL
        }
      });
      if(signUp.error)throw new Error(signUp.error.message);

      localStorage.removeItem(CONFIRM_FLAG);
      show('<div class="brand big">SHOP MANAGEMENT</div><h2>Confirm your email</h2><p class="muted">We sent a confirmation email to <b>'+esc(email)+'</b>.</p><div class="notice">Open the email and tap <b>Confirm your email address</b>. The confirmation link now goes to the real Shop Management website — not localhost.</div><div class="notice">Keep this page open. After you confirm the email, this page will automatically detect it, log you in and continue.</div><p id="confirmStatus" class="tiny">Waiting for email confirmation...</p>');

      for(let i=0;i<180;i++){
        await new Promise(r=>setTimeout(r,2000));

        // First check the shared flag written by the confirmation redirect tab.
        if(localStorage.getItem(CONFIRM_FLAG)){
          const confirmed=await client.auth.signInWithPassword({email,password});
          if(!confirmed.error){
            localStorage.removeItem(CONFIRM_FLAG);
            busy=false;
            location.reload();
            return;
          }
        }

        // Also try direct sign-in. This covers confirmation links that stay in
        // the same browser/session and makes the flow resilient across tabs.
        const confirmed=await client.auth.signInWithPassword({email,password});
        if(!confirmed.error){
          busy=false;
          location.reload();
          return;
        }

        const status=document.querySelector("#confirmStatus");
        if(status)status.textContent="Still waiting for confirmation… Please check your email.";
      }

      throw new Error("Confirmation timed out. Confirm the email and start registration again if this page is no longer waiting.");
    }catch(e){busy=false;message(e instanceof Error?e.message:String(e),"danger")}
  });
}
async function login(){
  if(busy)return;
  busy=true;

  const saved=localConnection();

  // Login on a new/reinstalled device starts by asking for the shop's
  // Supabase URL and publishable key. This flow is completely direct:
  // it never calls the Render setup/OAuth server.
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Connect your shop</h2><p class="muted">Enter the Supabase project URL and publishable key for this shop. The app connects directly to Supabase using your Wi-Fi or mobile data. Render is not used.</p><form id="directConnectionForm"><label>Supabase Project URL<input name="url" type="url" autocomplete="url" placeholder="https://xxxxx.supabase.co" value="'+esc(saved.url)+'" required></label><label>Publishable Key<input name="key" type="text" autocomplete="off" placeholder="sb_publishable_..." value="'+esc(saved.key)+'" required></label><button class="primary wide">Connect</button></form><p class="tiny">After a successful connection, the URL and publishable key are saved on this device. You can download them later from Settings.</p><button id="backToGate" class="ghost wide">Back</button>');

  document.querySelector("#backToGate")?.addEventListener("click",()=>{
    busy=false;
    renderGate();
  });

  document.querySelector<HTMLFormElement>("#directConnectionForm")?.addEventListener("submit",async e=>{
    e.preventDefault();
    const fd=new FormData(e.currentTarget as HTMLFormElement);
    const url=String(fd.get("url")||"").trim().replace(/\/$/,"");
    const key=String(fd.get("key")||"").trim();
    if(!url||!key)return message("Enter both the Supabase URL and publishable key.","danger");

    const button=document.querySelector<HTMLButtonElement>("#directConnectionForm button");
    if(button){button.disabled=true;button.textContent="Connecting...";}

    try{
      const client=createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
      const sessionResult=await client.auth.getSession();
      if(sessionResult.error)throw new Error(sessionResult.error.message);

      localStorage.setItem(URL_KEY,url);
      localStorage.setItem(KEY_KEY,key);

      // Move to the normal Supabase email/password login only after the
      // project connection has been verified. No Render request is made.
      show('<div class="brand big">SHOP MANAGEMENT</div><h2>Login</h2><div class="notice ok">✓ Supabase project connected</div><p class="muted">Now enter the Shop Owner email and password for this shop.</p><form id="directLogin"><label>Shop Owner Email<input name="email" type="email" autocomplete="email" required></label><label>Shop Owner Password<input name="password" type="password" autocomplete="current-password" required></label><button class="primary wide">Login</button></form><button id="changeConnection" class="ghost wide">Change Supabase Project</button><p class="tiny">This login goes directly to your Supabase project over Wi-Fi or mobile data. Render is not used.</p>');

      document.querySelector("#changeConnection")?.addEventListener("click",()=>{busy=false;login()});

      document.querySelector<HTMLFormElement>("#directLogin")?.addEventListener("submit",async e=>{
        e.preventDefault();
        const fd2=new FormData(e.currentTarget as HTMLFormElement);
        const email=String(fd2.get("email")||"").trim();
        const password=String(fd2.get("password")||"");
        if(!email||!password)return message("Enter your email and password.","danger");
        const loginButton=document.querySelector<HTMLButtonElement>("#directLogin button");
        if(loginButton){loginButton.disabled=true;loginButton.textContent="Logging in...";}
        try{
          await finishDirectLogin(email,password);
        }catch(err){
          if(loginButton){loginButton.disabled=false;loginButton.textContent="Login";}
          message(err instanceof Error?err.message:String(err),"danger");
        }
      });
    }catch(err){
      if(button){button.disabled=false;button.textContent="Connect";}
      message(err instanceof Error?err.message:"Could not connect to this Supabase project. Check the URL, publishable key, and internet connection.","danger");
    }
  });
}
async function start(){
  const confirmedRedirect=await handleEmailConfirmationRedirect();
  if(confirmedRedirect){
    location.replace(window.location.pathname+window.location.search);
    return;
  }
  renderGate();
}

function renderGate(){
  // Keep the entry screen unchanged in purpose: Register remains the existing
  // registration flow, while URL/key are requested only after Login is tapped.
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Welcome</h2><p class="muted">Connect your Supabase account once. After registration, everyday login works directly through Supabase.</p><button id="registerNow" class="primary wide">Register / Connect Supabase</button><button id="loginNow" class="ghost wide">Login</button><button id="appUpdateLogin" class="ghost wide" type="button">Check for App Update</button><p class="tiny">Tap Login to connect an existing shop. On a new install/device, enter that shop\'s Supabase URL and publishable key, then sign in.</p>');
  document.querySelector("#registerNow")?.addEventListener("click",register);
  document.querySelector("#appUpdateLogin")?.addEventListener("click",async()=>{const b=document.querySelector<HTMLButtonElement>("#appUpdateLogin");if(b){b.disabled=true;b.textContent="Checking..."}try{await checkForAppUpdate()}finally{const x=document.querySelector<HTMLButtonElement>("#appUpdateLogin");if(x){x.disabled=false;x.textContent="Check for App Update"}}});
  document.querySelector("#loginNow")?.addEventListener("click",login);
}
function shouldTakeOver(){
  const card=document.querySelector(".login-card");
  if(!card)return false;
  const t=card.textContent||"";
  return /Connect your database|Sign in to your shop|Database not set up/i.test(t);
}
const observer=new MutationObserver(()=>{
  if(!busy&&shouldTakeOver())renderGate();
});
observer.observe(document.documentElement,{subtree:true,childList:true});
setTimeout(()=>{if(!busy&&shouldTakeOver())start()},50);
