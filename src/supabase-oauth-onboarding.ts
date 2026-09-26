import { createClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { Browser } from "@capacitor/browser";

const RENDER_BASE="https://shop-management-oauth.onrender.com";
const URL_KEY="shop_management_supabase_url";
const KEY_KEY="shop_management_supabase_publishable_key";
let busy=false;

const esc=(s:any)=>String(s??"").replace(/[&<>\"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));

function localConnection(){
  return {url:localStorage.getItem(URL_KEY)||"",key:localStorage.getItem(KEY_KEY)||""};
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
      const organizations=ready.organizations||[];
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
      const client=createClient(installed.url,installed.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
      let auth=await client.auth.signUp({email,password,options:{data:{full_name:name}}});
      if(auth.error && /already registered|already exists/i.test(auth.error.message||"")){
        auth=await client.auth.signInWithPassword({email,password});
      }
      if(auth.error && !/already registered|already exists/i.test(auth.error.message||""))throw new Error(auth.error.message);
      if(!auth.data.session){
        message("Confirming your Shop Management email automatically...");
        await api("/api/oauth/confirm-user",{method:"POST",body:JSON.stringify({session_id:start.session_id,project_ref:ref,email})});
        const sign=await client.auth.signInWithPassword({email,password});
        if(sign.error)throw new Error("Automatic email confirmation failed: "+sign.error.message);
      }else{
        await api("/api/oauth/confirm-user",{method:"POST",body:JSON.stringify({session_id:start.session_id,project_ref:ref,email})}).catch(()=>{});
      }
      busy=false;
      location.reload();
    }catch(e){busy=false;message(e instanceof Error?e.message:String(e),"danger")}
  });
}
async function login(){
  if(busy)return;busy=true;
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Login</h2><p class="muted">Your Supabase connection is already saved on this device. Render is not used for normal login.</p><form id="localLogin"><label>Shop Owner Email<input name="email" type="email" autocomplete="email" required></label><label>Shop Owner Password<input name="password" type="password" autocomplete="current-password" required></label><button class="primary wide">Login</button></form><button id="registerInstead" class="ghost wide">Register / Connect Supabase</button><p class="tiny">After registration, this Login works directly against your Supabase project, even if Render is offline.</p>');
  document.querySelector("#registerInstead")?.addEventListener("click",()=>{busy=false;register()});
  document.querySelector("#localLogin")?.addEventListener("submit",async e=>{
    e.preventDefault();
    const fd=new FormData(e.currentTarget as HTMLFormElement);
    try{await finishDirectLogin(String(fd.get("email")||"").trim(),String(fd.get("password")||""))}
    catch(e){message(e instanceof Error?e.message:String(e),"danger")}
  });
}
function renderGate(){
  const c=localConnection();
  if(c.url&&c.key){
    login();
  }else{
    show('<div class="brand big">SHOP MANAGEMENT</div><h2>Welcome</h2><p class="muted">Connect your Supabase account once. After registration, everyday login works directly through Supabase.</p><button id="registerNow" class="primary wide">Register / Connect Supabase</button><button id="loginNow" class="ghost wide">Login</button><p class="tiny">Login needs a saved Supabase connection. On a new install/device, register/connect once again.</p>');
    document.querySelector("#registerNow")?.addEventListener("click",register);
    document.querySelector("#loginNow")?.addEventListener("click",login);
  }
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
setTimeout(()=>{if(!busy&&shouldTakeOver())renderGate()},50);
