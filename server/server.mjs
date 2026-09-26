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
        session.projects=await supa("/v1/projects",session.tokens.access_token);        session.organizations=await supa("/v1/organizations",session.tokens.access_token);
        return html(res,200,"<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{font-family:system-ui;padding:32px;background:#0f172a;color:#fff}main{max-width:520px;margin:auto;background:#111c32;padding:28px;border-radius:20px}b{color:#7dd3fc}</style><main><h2>Supabase connected ✓</h2><p>You can now return to the <b>Shop Management</b> app.</p><p>Keep this page open until the app finishes setup.</p></main>");
      }catch(e){session.status="error";session.error=e instanceof Error?e.message:String(e);return html(res,500,"<h2>Supabase connection failed</h2><p>Return to the app and try again.</p>")}
    }
    if(u.pathname==="/api/oauth/status" && req.method==="GET"){
      const s=sessions.get(u.searchParams.get("session")||"");
      if(!s)return json(res,404,{error:"Registration session expired."});
      if(s.status==="error")return json(res,400,{error:s.error||"Authorization failed."});
      return json(res,200,{status:s.status,organizations:s.status==="ready"?(s.organizations||[]).map(o=>({id:o.id,name:o.name,slug:o.slug})):[],projects:s.status==="ready"?(s.projects||[]).map(p=>({ref:p.ref,name:p.name,region:p.region,status:p.status})):[]});
    }
    if(u.pathname==="/api/oauth/create-project" && req.method==="POST"){      const b=await body(req),s=sessions.get(String(b.session_id||""));      if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready."});      const organization_id=String(b.organization_id||"");      const name=String(b.name||"Shop Management").trim().slice(0,60);      const region=String(b.region||"ap-southeast-1");      if(!organization_id)return json(res,400,{error:"Select a Supabase organization."});      if(!name)return json(res,400,{error:"Enter a project name."});      try{        const project=await createProject(s.tokens.access_token,{organization_id,name,region});        const ready=await waitProject(project.ref,s.tokens.access_token);        s.projects=[...(s.projects||[]),ready];        return json(res,200,{ok:true,project:{ref:ready.ref,name:ready.name,region:ready.region,status:ready.status}});      }catch(e){return json(res,500,{error:e instanceof Error?e.message:String(e)});}    }    if(u.pathname==="/api/oauth/install" && req.method==="POST"){
      const b=await body(req),s=sessions.get(String(b.session_id||"")),ref=String(b.project_ref||"");
      if(!s||s.status!=="ready"||!s.tokens?.access_token)return json(res,400,{error:"Registration session is not ready."});
      const project=(s.projects||[]).find(p=>p.ref===ref);
      if(!project)return json(res,400,{error:"Selected Supabase project was not found in your account."});
      const token=s.tokens.access_token;
      await supa("/v1/projects/"+encodeURIComponent(ref)+"/database/query",token,{method:"POST",body:JSON.stringify({query:sql,read_only:false})});
      try{
        await supa("/v1/projects/"+encodeURIComponent(ref)+"/config/auth",token,{method:"PATCH",body:JSON.stringify({disable_signup:false,external_email_enabled:true,mailer_autoconfirm:true})});
      }catch(e){
        const detail=e instanceof Error?e.message:String(e);
        return json(res,500,{error:"Database installed, but Supabase Auth configuration failed.",detail});
      }
      const key=await getPublishableKey(ref,token);
      const url="https://"+ref+".supabase.co";
      sessions.delete(String(b.session_id||""));
      return json(res,200,{ok:true,url,key,project:{ref:project.ref,name:project.name}});
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
