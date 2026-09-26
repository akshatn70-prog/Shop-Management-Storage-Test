import { createClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { Browser } from "@capacitor/browser";

const RENDER_BASE="https://shop-management-storage-test.onrender.com";
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
  if(!r.ok)throw new Error(d.error||"Render setup server error");
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
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Register Shop Owner</h2><p class="muted">This one-time process connects your own Supabase account, installs the database automatically, and then signs you in.</p><form id="ownerReg"><label>Full name<input name="name" autocomplete="name" required></label><label>Email<input name="email" type="email" autocomplete="email" required></label><label>Password<input name="password" type="password" minlength="6" autocomplete="new-password" required></label><button class="primary wide">Connect Supabase & Register</button></form><button id="backLogin" class="ghost wide">Back to Login</button>');
  document.querySelector("#backLogin")?.addEventListener("click",()=>{busy=false;renderGate()});
  document.querySelector("#ownerReg")?.addEventListener("submit",async e=>{
    e.preventDefault();
    const fd=new FormData(e.currentTarget as HTMLFormElement),name=String(fd.get("name")||"").trim(),email=String(fd.get("email")||"").trim(),password=String(fd.get("password")||"");
    if(!name||!email||password.length<6)return message("Enter your name, email and a password of at least 6 characters.","danger");
    try{
      message("Starting secure Supabase authorization...");
      const start=await api("/api/oauth/start",{method:"POST",body:"{}"});
      message("Supabase opened. Sign in and press Allow. Keep this app open while you authorize.");
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
      if(!projects.length)throw new Error("Your Supabase account has no project yet. Create a Supabase project first, then register again.");
      let ref=projects.length===1?projects[0].ref:"";
      if(!ref){
        show('<div class="brand big">SHOP MANAGEMENT</div><h2>Choose your Supabase project</h2><p class="muted">Select the project that will store this shop.</p><select id="projectPick" class="wide">'+projects.map((p:any)=>'<option value="'+esc(p.ref)+'">'+esc(p.name)+" — "+esc(p.region||"")+'</option>').join("")+'</select><button id="installSelected" class="primary wide">Install Shop Management</button>');
        await new Promise<void>((resolve,reject)=>{
          document.querySelector("#installSelected")?.addEventListener("click",async()=>{
            ref=String((document.querySelector("#projectPick") as HTMLSelectElement).value||"");
            try{resolve()}catch(e){reject(e)}
          });
        });
      }
      show('<div class="brand big">SHOP MANAGEMENT</div><h2>Installing...</h2><p class="muted">Creating the database, security, functions and Auth settings.</p><div class="notice">Please keep this screen open.</div>');
      const installed=await api("/api/oauth/install",{method:"POST",body:JSON.stringify({session_id:start.session_id,project_ref:ref})});
      localStorage.setItem(URL_KEY,installed.url);
      localStorage.setItem(KEY_KEY,installed.key);
      const client=createClient(installed.url,installed.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
      let auth=await client.auth.signUp({email,password,options:{data:{full_name:name}}});
      if(auth.error && /already registered|already exists/i.test(auth.error.message||"")){
        auth=await client.auth.signInWithPassword({email,password});
      }
      if(auth.error)throw new Error(auth.error.message);
      if(!auth.data.session){
        const sign=await client.auth.signInWithPassword({email,password});
        if(sign.error)throw new Error("Account created. Sign in once with your email and password: "+sign.error.message);
      }
      busy=false;
      location.reload();
    }catch(e){busy=false;message(e instanceof Error?e.message:String(e),"danger")}
  });
}
async function login(){
  if(busy)return;busy=true;
  show('<div class="brand big">SHOP MANAGEMENT</div><h2>Login</h2><p class="muted">Your Supabase connection is already saved on this device. Render is not used for normal login.</p><form id="localLogin"><label>Email<input name="email" type="email" autocomplete="email" required></label><label>Password<input name="password" type="password" autocomplete="current-password" required></label><button class="primary wide">Login</button></form><button id="registerInstead" class="ghost wide">Register / Connect Supabase</button><p class="tiny">After registration, this Login works directly against your Supabase project, even if Render is offline.</p>');
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
