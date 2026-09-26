import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const PORT=Number(process.env.PORT||10000);
const HOST="0.0.0.0";
const OAUTH_CLIENT_ID=process.env.SUPABASE_OAUTH_CLIENT_ID||"";
const OAUTH_CLIENT_SECRET=process.env.SUPABASE_OAUTH_CLIENT_SECRET||"";
const OAUTH_REDIRECT_URI=process.env.SUPABASE_OAUTH_REDIRECT_URI||"";
const OAUTH_TICKET_SECRET=process.env.OAUTH_TICKET_SECRET||"";
const APP_ORIGIN=process.env.APP_ORIGIN||"*";

const sessions=new Map();
const __dirname=path.dirname(fileURLToPath(import.meta.url));
const sqlPath=path.join(__dirname,"..","public","shop-management-final.sql");
const sql=fs.readFileSync(sqlPath,"utf8");

function json(res,status,data){
  res.statusCode=status;
  res.setHeader("Content-Type","application/json; charset=utf-8");
  res.setHeader("Cache-Control","no-store");
  res.setHeader("Access-Control-Allow-Origin",APP_ORIGIN);
  res.setHeader("Access-Control-Allow-Headers","Content-Type");
  res.setHeader("Access-Control-Allow-Methods","GET,POST,OPTIONS");
  res.end(JSON.stringify(data));
}
function html(res,status,body){
  res.statusCode=status;
  res.setHeader("Content-Type","text/html; charset=utf-8");
  res.end(body);
}
function random(size=32){return crypto.randomBytes(size).toString("base64url")}
function ticketKey(){return crypto.createHash("sha256").update(OAUTH_TICKET_SECRET).digest()}
function makeSetupTicket(payload){
  const iv=crypto.randomBytes(12);
  const cipher=crypto.createCipheriv("aes-256-gcm",ticketKey(),iv);
  const text=JSON.stringify(payload);
  const enc=Buffer.concat([cipher.update(text,"utf8"),cipher.final()]);
  const tag=cipher.getAuthTag();
  return Buffer.concat([iv,tag,enc]).toString("base64url");
}
function readSetupTicket(ticket){
  const raw=Buffer.from(String(ticket||""),"base64url");
  if(raw.length<28)throw new Error("Invalid registration setup ticket.");
  const iv=raw.subarray(0,12),tag=raw.subarray(12,28),enc=raw.subarray(28);
  const decipher=crypto.createDecipheriv("aes-256-gcm",ticketKey(),iv);
  decipher.setAuthTag(tag);
  return JSON.parse(Buffer.concat([decipher.update(enc),decipher.final()]).toString("utf8"));
}
function pkceChallenge(verifier){return crypto.createHash("sha256").update(verifier).digest("base64url")}
function body(req){
  return new Promise((resolve,reject)=>{
    let s="";req.on("data",c=>{s+=c;if(s.length>2_000_000)req.destroy()});
    req.on("end",()=>{try{resolve(s?JSON.parse(s):{})}catch(e){reject(e)}});
    req.on("error",reject);
  });
}
async function supa(pathname,token,options={}){
  const r=await fetch("https://api.supabase.com"+pathname,{
    ...options,
    headers:{
      Authorization:"Bearer "+token,
      "Content-Type":"application/json",
      Accept:"application/json",
      ...(options.headers||{})
    }
  });
  const text=await r.text();
  let data;try{data=text?JSON.parse(text):{}}catch{data={raw:text}}
  if(!r.ok)throw new Error((data?.message||data?.error_description||data?.error||"Supabase Management API error")+" (HTTP "+r.status+")");
  return data;
}
async function exchange(code,verifier){
  const basic=Buffer.from(OAUTH_CLIENT_ID+":"+OAUTH_CLIENT_SECRET).toString("base64");
  const r=await fetch("https://api.supabase.com/v1/oauth/token",{
    method:"POST",
    headers:{Authorization:"Basic "+basic,"Content-Type":"application/x-www-form-urlencoded",Accept:"application/json"},
    body:new URLSearchParams({
      grant_type:"authorization_code",
      code,
      redirect_uri:OAUTH_REDIRECT_URI,
      code_verifier:verifier
    })
  });
  const data=await r.json();
  if(!r.ok)throw new Error(data?.error_description||data?.error||"Supabase OAuth token exchange failed");
  return data;
}
async function getSecretKey(ref,token){
  let keys=await supa("/v1/projects/"+encodeURIComponent(ref)+"/api-keys?reveal=true",token);
  if(!Array.isArray(keys))keys=keys?.keys||[];
  let key=keys.find(x=>(x.type==="secret"||x.type==="service_role") && x.api_key)?.api_key||"";
  if(!key){
    const created=await supa("/v1/projects/"+encodeURIComponent(ref)+"/api-keys?reveal=true",token,{
      method:"POST",
      body:JSON.stringify({type:"secret",name:"shop-management-admin"})
    });
    key=created?.api_key||"";
  }
  if(!key)throw new Error("No secret API key is available for this Supabase project.");
  return key;
}
async function getOrganizations(token){
  let lastError=null;
  for(let i=0;i<4;i++){
    try{
      const orgs=await supa("/v1/organizations",token);
      if(Array.isArray(orgs) && orgs.length)return orgs;
      if(Array.isArray(orgs))return orgs;
      lastError=new Error("Supabase returned no organizations.");
    }catch(e){lastError=e;}
    if(i<3)await new Promise(r=>setTimeout(r,1200));
  }
  throw lastError||new Error("Could not load Supabase organizations.");
}
async function getPublishableKey(ref,token){
  let keys=await supa("/v1/projects/"+encodeURIComponent(ref)+"/api-keys?reveal=true",token);
  if(!Array.isArray(keys))keys=keys?.keys||[];
  let key=keys.find(x=>x.type==="publishable" && x.api_key)?.api_key||"";
  if(!key){
    const created=await supa("/v1/projects/"+encodeURIComponent(ref)+"/api-keys?reveal=true",token,{
      method:"POST",
      body:JSON.stringify({type:"publishable",name:"shop-management"})
    });
    key=created?.api_key||"";
  }
  if(!key)throw new Error("No publishable API key is available for this Supabase project.");
  return key;
}
async function createProject(token,{organization_id,name,region}){  const dbPass=random(24)+"A1!";  return await supa("/v1/projects",token,{method:"POST",body:JSON.stringify({organization_id,name,region,db_pass:dbPass})});}
async function waitProject(ref,token){
  for(let i=0;i<60;i++){
    const p=await supa("/v1/projects/"+encodeURIComponent(ref),token);
    const status=String(p?.status||"").toUpperCase();
    if(status==="ACTIVE_HEALTHY" || status==="ACTIVE" || status==="HEALTHY")return p;
    try{
      const h=await supa("/v1/projects/"+encodeURIComponent(ref)+"/health",token);
      const services=Array.isArray(h)?h:(h?.services||h?.data||[]);
      const allHealthy=Array.isArray(services) && services.length>0 && services.every(x=>String(x?.status||"").toUpperCase()==="ACTIVE_HEALTHY");
      if(allHealthy)return p;
    }catch{}
    await new Promise(r=>setTimeout(r,5000));
  }
  throw new Error("Supabase project is still starting. Please wait a few minutes and try again.");
}function cleanup(){
  const now=Date.now();
  for(const [id,s] of sessions)if(now-s.createdAt>15*60*1000)sessions.delete(id);
}
setInterval(cleanup,60_000).unref();

const server=http.createServer(async(req,res)=>{
  if(req.method==="OPTIONS"){
    res.statusCode=204;
    res.setHeader("Access-Control-Allow-Origin",APP_ORIGIN);
    res.setHeader("Access-Control-Allow-Headers","Content-Type");
    res.setHeader("Access-Control-Allow-Methods","GET,POST,OPTIONS");
    return res.end();
  }
  const u=new URL(req.url||"/","http://localhost");
  try{
    if(u.pathname==="/health")return json(res,200,{ok:true});
    if(u.pathname==="/api/oauth/start" && req.method==="POST"){
      if(!OAUTH_CLIENT_ID||!OAUTH_CLIENT_SECRET||!OAUTH_REDIRECT_URI||!OAUTH_TICKET_SECRET)throw new Error("Render OAuth environment variables are not configured.");
      const sessionId=random(24),state=random(24),verifier=random(48);
      sessions.set(sessionId,{createdAt:Date.now(),state,verifier,status:"waiting"});
      const auth=new URL("https://api.supabase.com/v1/oauth/authorize");
      auth.searchParams.set("response_type","code");
      auth.searchParams.set("client_id",OAUTH_CLIENT_ID);
      auth.searchParams.set("redirect_uri",OAUTH_REDIRECT_URI);
      auth.searchParams.set("state",state);
      auth.searchParams.set("code_challenge",pkceChallenge(verifier));
      auth.searchParams.set("code_challenge_method","S256");
      return json(res,200,{session_id:sessionId,authorize_url:auth.toString()});
    }
    if(u.pathname==="/oauth/callback" && req.method==="GET"){
      const code=u.searchParams.get("code")||"",state=u.searchParams.get("state")||"",error=u.searchParams.get("error")||"";
      const session=[...sessions.values()].find(s=>s.state===state);
      if(!session)return html(res,400,"<h2>Shop Management authorization expired.</h2><p>Return to the app and start registration again.</p>");
      if(error){session.status="error";session.error=u.searchParams.get("error_description")||error;return html(res,400,"<h2>Authorization cancelled</h2><p>Return to Shop Management and try again.</p>")}
      if(!code)return html(res,400,"<h2>No authorization code received.</h2>");
      try{
        session.tokens=await exchange(code,session.verifier);
        session.status="ready";
        session.projects=await supa("/v1/projects",session.tokens.access_token);
        try{session.organizations=await getOrganizations(session.tokens.access_token);session.organization_error="";}
        catch(e){session.organizations=[];session.organization_error=e instanceof Error?e.message:String(e);}
        return html(res,200,"<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{font-family:system-ui;padding:32px;background:#0f172a;color:#fff}main{max-width:520px;margin:auto;background:#111c32;padding:28px;border-radius:20px}b{color:#7dd3fc}</style><main><h2>Supabase connected ✓</h2><p>You can now return to the <b>Shop Management</b> app.</p><p>Keep this page open until the app finishes setup.</p></main>");
      }catch(e){session.status="error";session.error=e instanceof Error?e.message:String(e);return html(res,500,"<h2>Supabase connection failed</h2><p>Return to the app and try again.</p>")}
    }
    if(u.pathname==="/api/oauth/status" && req.method==="GET"){
      const s=sessions.get(u.searchParams.get("session")||"");
      if(!s)return json(res,404,{error:"Registration session expired."});
      if(s.status==="error")return json(res,400,{error:s.error||"Authorization failed."});
      if(s.status==="ready" && (!Array.isArray(s.organizations)||s.organizations.length===0) && s.tokens?.access_token){
        try{const orgs=await getOrganizations(s.tokens.access_token);s.organizations=orgs;s.organization_error="";}
        catch(e){s.organization_error=e instanceof Error?e.message:String(e);}
      }
      return json(res,200,{status:s.status,organizations:s.status==="ready"?(s.organizations||[]).map(o=>({id:o.id,name:o.name,slug:o.slug})):[],organization_error:s.status==="ready"?(s.organization_error||""): "",projects:s.status==="ready"?(s.projects||[]).map(p=>({ref:p.ref,name:p.name,region:p.region,status:p.status})):[]});
    }
    if(u.pathname==="/api/oauth/create-project" && req.method==="POST"){      const b=await body(req),s=sessions.get(String(b.session_id||""));      if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready."});      const organization_id=String(b.organization_id||"");      const name=String(b.name||"Shop Management").trim().slice(0,60);      const region=String(b.region||"ap-southeast-1");      if(!organization_id)return json(res,400,{error:"Select a Supabase organization."});      if(!name)return json(res,400,{error:"Enter a project name."});      try{        const project=await createProject(s.tokens.access_token,{organization_id,name,region});        const ready=await waitProject(project.ref,s.tokens.access_token);        s.projects=[...(s.projects||[]),ready];        return json(res,200,{ok:true,project:{ref:ready.ref,name:ready.name,region:ready.region,status:ready.status}});      }catch(e){return json(res,500,{error:e instanceof Error?e.message:String(e)});}    }    if(u.pathname==="/api/oauth/install" && req.method==="POST"){
      const b=await body(req),s=sessions.get(String(b.session_id||"")),ref=String(b.project_ref||"");
      if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready."});
      const project=(s.projects||[]).find(p=>p.ref===ref);
      if(!project)return json(res,400,{error:"Selected Supabase project was not found in your account."});
      const token=s.tokens.access_token;
      await supa("/v1/projects/"+encodeURIComponent(ref)+"/database/query",token,{method:"POST",body:JSON.stringify({query:sql,read_only:false})});
      try{
        // Keep Supabase's normal confirmation-email flow. Free-tier projects using
        // Supabase's default email provider cannot change the email template.
        // The important part is that Site URL / redirect allow-list point to the
        // real production website instead of Supabase's default localhost URL.
        await supa("/v1/projects/"+encodeURIComponent(ref)+"/config/auth",token,{method:"PATCH",body:JSON.stringify({
          site_url:"https://shop-management-storage-test.onrender.com",
          uri_allow_list:"https://shop-management-storage-test.onrender.com",
          disable_signup:false,
          external_email_enabled:true,
          mailer_autoconfirm:false
        })});
      }catch(e){
        const detail=e instanceof Error?e.message:String(e);
        return json(res,500,{error:"Database installed, but Supabase Auth configuration failed.",detail});
      }
      const key=await getPublishableKey(ref,token);
      const url="https://"+ref+".supabase.co";
      const setup_ticket=makeSetupTicket({ref,access_token:token,created_at:Date.now()});
      return json(res,200,{ok:true,url,key,setup_ticket,project:{ref:project.ref,name:project.name}});
    }
    if(u.pathname==="/api/oauth/create-owner" && req.method==="POST"){
      const b=await body(req),sessionId=String(b.session_id||""),ticket=String(b.setup_ticket||""),email=String(b.email||"").trim().toLowerCase(),password=String(b.password||""),name=String(b.name||"").trim();
      let s=sessionId?sessions.get(sessionId):null,ref=String(b.project_ref||""),accessToken="";
      if(ticket){
        try{
          const t=readSetupTicket(ticket);
          if(Date.now()-Number(t.created_at||0)>20*60*1000)throw new Error("Registration setup ticket expired.");
          ref=String(t.ref||ref);accessToken=String(t.access_token||"");
        }catch(e){return json(res,400,{error:e instanceof Error?e.message:String(e)});}
      }
      if(!email||!password||!ref)return json(res,400,{error:"Email, password and project are required."});
      if(password.length<6)return json(res,400,{error:"Password must be at least 6 characters."});
      if(!accessToken){
        if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready. Please restart registration."});
        accessToken=s.tokens.access_token;
      }
      try{
        const secret=await getSecretKey(ref,accessToken);
        const listRes=await fetch("https://"+ref+".supabase.co/auth/v1/admin/users?per_page=1000",{headers:{apikey:secret,Authorization:"Bearer "+secret,Accept:"application/json"}});
        const list=await listRes.json().catch(()=>({}));
        if(!listRes.ok)throw new Error((list?.msg||list?.message||"Supabase Auth admin request failed")+" (HTTP "+listRes.status+")");
        const users=Array.isArray(list)?list:(list?.users||[]);
        const existing=users.find(x=>String(x?.email||"").toLowerCase()===email);
        if(existing){
          if(!existing.email_confirmed_at){
            const ur=await fetch("https://"+ref+".supabase.co/auth/v1/admin/users/"+encodeURIComponent(existing.id),{method:"PUT",headers:{apikey:secret,Authorization:"Bearer "+secret,"Content-Type":"application/json",Accept:"application/json"},body:JSON.stringify({email_confirm:true})});
            const ud=await ur.json().catch(()=>({}));
            if(!ur.ok)throw new Error((ud?.msg||ud?.message||"Supabase could not confirm the owner email")+" (HTTP "+ur.status+")");
            return json(res,200,{ok:true,confirmed:true,existing:true});
          }
          return json(res,200,{ok:false,error:"OWNER_ALREADY_REGISTERED"});
        }
        const ur=await fetch("https://"+ref+".supabase.co/auth/v1/admin/users",{method:"POST",headers:{apikey:secret,Authorization:"Bearer "+secret,"Content-Type":"application/json",Accept:"application/json"},body:JSON.stringify({email,password,email_confirm:true,user_metadata:{full_name:name}})});
        const ud=await ur.json().catch(()=>({}));
        if(!ur.ok)throw new Error((ud?.msg||ud?.message||"Supabase could not create the owner account")+" (HTTP "+ur.status+")");
        if(sessionId)sessions.delete(sessionId);
        return json(res,200,{ok:true,confirmed:true,created:true});
      }catch(e){return json(res,500,{error:"The owner account could not be created automatically.",detail:e instanceof Error?e.message:String(e)});}
    }
    if(u.pathname==="/api/oauth/confirm-user" && req.method==="POST"){
      const b=await body(req),sessionId=String(b.session_id||""),ticket=String(b.setup_ticket||""),email=String(b.email||"").trim().toLowerCase();
      let s=sessionId?sessions.get(sessionId):null;
      let ref=String(b.project_ref||""),accessToken="";
      if(ticket){
        try{
          const t=readSetupTicket(ticket);
          if(Date.now()-Number(t.created_at||0)>20*60*1000)throw new Error("Registration setup ticket expired.");
          ref=String(t.ref||ref);accessToken=String(t.access_token||"");
        }catch(e){return json(res,400,{error:e instanceof Error?e.message:String(e)});}
      }
      if(!email||!ref)return json(res,400,{error:"Project and email are required."});
      if(!accessToken){
        if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready. Please restart registration."});
        accessToken=s.tokens.access_token;
      }
      const project=s?.projects?.find(p=>p.ref===ref);
      if(s && !project)return json(res,400,{error:"Selected Supabase project was not found in your account."});
      if(!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email))return json(res,400,{error:"Enter a valid email address."});
      try{
        const secret=await getSecretKey(ref,accessToken);
        const r=await fetch("https://"+ref+".supabase.co/auth/v1/admin/users?per_page=1000",{
          headers:{apikey:secret,Authorization:"Bearer "+secret,Accept:"application/json"}
        });
        const list=await r.json().catch(()=>({}));
        if(!r.ok)throw new Error((list?.msg||list?.message||"Supabase Auth admin request failed")+" (HTTP "+r.status+")");
        const users=Array.isArray(list)?list:(list?.users||[]);
        const user=users.find(x=>String(x?.email||"").toLowerCase()===email);
        if(!user)return json(res,404,{error:"The owner account was not found in the new Supabase project."});
        if(!user.email_confirmed_at){
          const ur=await fetch("https://"+ref+".supabase.co/auth/v1/admin/users/"+encodeURIComponent(user.id),{
            method:"PUT",
            headers:{apikey:secret,Authorization:"Bearer "+secret,"Content-Type":"application/json",Accept:"application/json"},
            body:JSON.stringify({email_confirm:true})
          });
          const ud=await ur.json().catch(()=>({}));
          if(!ur.ok)throw new Error((ud?.msg||ud?.message||"Supabase could not confirm the owner email")+" (HTTP "+ur.status+")");
        }
        if(sessionId)sessions.delete(sessionId);
        return json(res,200,{ok:true,confirmed:true});
      }catch(e){
        return json(res,500,{error:"The owner account was created, but automatic email confirmation failed.",detail:e instanceof Error?e.message:String(e)});
      }
    }
    if(u.pathname.startsWith("/api/"))return json(res,404,{error:"Not found"});

    const dist=path.join(__dirname,"..","dist");
    let filePath=path.join(dist,u.pathname==="/"?"index.html":u.pathname.replace(/^\//,""));
    if(!path.extname(filePath))filePath=path.join(dist,"index.html");
    if(!filePath.startsWith(dist))return html(res,403,"Forbidden");
    if(!fs.existsSync(filePath))return html(res,404,"Not found");
    const ext=path.extname(filePath);
    const types={".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",".css":"text/css; charset=utf-8",".json":"application/json",".svg":"image/svg+xml",".png":"image/png",".webmanifest":"application/manifest+json"};
    res.statusCode=200;res.setHeader("Content-Type",types[ext]||"application/octet-stream");
    fs.createReadStream(filePath).pipe(res);
  }catch(e){
    json(res,500,{error:e instanceof Error?e.message:String(e)});
  }
});
server.listen(PORT,HOST,()=>console.log("Shop Management web service listening on "+HOST+":"+PORT));
