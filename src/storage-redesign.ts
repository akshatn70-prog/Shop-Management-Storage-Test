import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { ShopDownloads } from "@shop-management/downloads";
import { checkForAppUpdate } from "./app-updater";
import "./styles.css";

type Role="owner"|"worker";
type Profile={id:string;full_name:string;email:string;role:Role;is_active:boolean;shop_id?:string};
type Product={id:string;name:string;unit_type:"piece"|"weight";weight_price_unit?: "kg"|"grams";current_stock_base:number;purchase_price_per_base_unit:number;selling_price_per_base_unit:number;low_stock_threshold_base:number;photo_path?:string|null;is_active:boolean};
type AnyRow=Record<string,any>;
type SaleVoidGroup={key:string;transactionId:string|null;rows:AnyRow[]};

const URL_KEY="shop_management_supabase_url", KEY_KEY="shop_management_supabase_publishable_key";
let supabase:SupabaseClient|null=null, profile:Profile|null=null;
type Theme="current"|"light-pink"|"pink";
const THEME_KEY="shop_management_theme";
const normalizeTheme=(value:any):Theme=>value==="light-pink"||value==="pink"||value==="current"?value:"current";
let settings:any={shop_name:"My Shop",currency:"INR",timezone:"Asia/Kolkata",workers_can_modify_selling_price:false,allow_below_cost_sales:true,allow_zero_price_sales:true,dashboard_reset_time:"00:00",theme:"current"};
let products:Product[]=[], sales:AnyRow[]=[], purchases:AnyRow[]=[], creditors:AnyRow[]=[], ledger:AnyRow[]=[], debtors:AnyRow[]=[], debtorLedger:AnyRow[]=[], daily:AnyRow[]=[], auditRows:AnyRow[]=[], workersRows:Profile[]=[], lifetime:any={};
let demo=false, demoReady=false, activeTab="dashboard", historyType="sales", historyRange="today", historyDate="", reportDate="", purchaseDate="", auditDate="";
let bottomNavScrollLeft=0, reportTableScrollLeft=0, dashboardSummaryKind="";
let realtimeChannel:any=null;
let realtimeRefreshTimer:number|undefined;
let cartItems:AnyRow[]=[], returnsRows:AnyRow[]=[], lowStockOnly=false;
const voidingSaleKeys=new Set<string>();
/**
 * Expected database contract for cart-aware voids:
 * public.void_sale_transaction(p_transaction_id uuid, p_reason text) returns void.
 * The RPC is owner-only and must atomically lock a confirmed sale_transactions row,
 * mark it and every linked sales row voided, restore stock, reverse credit-ledger
 * effects/aggregates, write an audit entry, and reject blank or repeated voids.
 * Legacy single-line rows without transaction_id continue to use void_sale(uuid,text).
 */
const CART_VOID_RPC="void_sale_transaction";
const app=document.querySelector<HTMLDivElement>("#app")!;

const iconForPayment=(mode:string)=>mode==="upi"?"UPI":mode==="split"?"⇄":"₹";
const m=(l:string,v:string)=>'<button type="button" class="metric metric-button" data-dashboard-summary="'+esc(l).toLowerCase().replace(/[^a-z]+/g,"-")+'"><span>'+l+'</span><b class="metric-value">'+v+'</b></button>';
const money=(n:any)=>new Intl.NumberFormat("en-IN",{style:"currency",currency:settings.currency||"INR",maximumFractionDigits:2}).format(Number(n)||0);
const saleTotal=(p:Product|null|undefined,quantityBase:number,sellingPricePerBaseUnit:number)=>{if(p?.unit_type!=="weight")return quantityBase*sellingPricePerBaseUnit;return (p.weight_price_unit||"kg")==="grams"?quantityBase*sellingPricePerBaseUnit:(quantityBase/1000)*sellingPricePerBaseUnit};
const saleCreditAmount=(sale:AnyRow)=>{const explicit=Number(sale?.credit_amount);if(Number.isFinite(explicit)&&explicit>0)return explicit;if(sale?.payment_mode==="credit"||sale?.payment_mode==="credit_split")return Math.max(0,Number(sale?.total_sale||0)-Number(sale?.cash_amount||0)-Number(sale?.upi_amount||0));return 0};
const esc=(s:any)=>String(s??"").replace(/[&<>\"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
const PRODUCT_PHOTO_BUCKET="product-photos";
type CompressedProductPhoto={blob:Blob;contentType:string;extension:"webp"|"jpg"};
const compressProductPhoto=async(file:File):Promise<CompressedProductPhoto>=>{
 if(!file.type.startsWith("image/"))throw new Error("Please select an image file.");
 const sourceUrl=URL.createObjectURL(file);
 try{
  const image=await new Promise<HTMLImageElement>((resolve,reject)=>{const img=new Image();img.onload=()=>resolve(img);img.onerror=()=>reject(new Error("The selected image could not be read."));img.src=sourceUrl});
  const maxSide=1200,scale=Math.min(1,maxSide/Math.max(image.naturalWidth||image.width,image.naturalHeight||image.height));
  const canvas=document.createElement("canvas");canvas.width=Math.max(1,Math.round((image.naturalWidth||image.width)*scale));canvas.height=Math.max(1,Math.round((image.naturalHeight||image.height)*scale));
  const ctx=canvas.getContext("2d");if(!ctx)throw new Error("Image compression is not supported on this device.");ctx.drawImage(image,0,0,canvas.width,canvas.height);
  const webp=await new Promise<Blob|null>(resolve=>canvas.toBlob(resolve,"image/webp",0.80));if(webp)return {blob:webp,contentType:"image/webp",extension:"webp"};
  const jpg=await new Promise<Blob|null>(resolve=>canvas.toBlob(resolve,"image/jpeg",0.82));if(!jpg)throw new Error("The image could not be compressed.");return {blob:jpg,contentType:"image/jpeg",extension:"jpg"};
 }finally{URL.revokeObjectURL(sourceUrl)}
};
const productPhotoUrl=(path?:string|null)=>{if(!path||demo||!supabase)return "";return supabase.storage.from(PRODUCT_PHOTO_BUCKET).getPublicUrl(path).data.publicUrl||""};
const productPhotoMarkup=(p:Product,compact=false)=>{
 const url=productPhotoUrl(p.photo_path);
 return url?'<div class="product-photo '+(compact?"product-photo-compact":"")+'"><img src="'+esc(url)+'" alt="'+esc(p.name)+'" loading="lazy"></div>':'<div class="product-photo product-photo-empty '+(compact?"product-photo-compact":"")+'" aria-label="No photo"><span class="ui-icon product-photo-placeholder-icon" aria-hidden="true"></span></div>';
};
const uploadProductPhoto=async(productId:string,file:File)=>{
 if(demo)throw new Error("Photos are not available in demo mode.");if(!supabase)throw new Error("Supabase is not connected.");
 const compressed=await compressProductPhoto(file),path="products/"+productId+"/"+Date.now()+"-"+Math.random().toString(36).slice(2,8)+"."+compressed.extension;
 const upload=await supabase.storage.from(PRODUCT_PHOTO_BUCKET).upload(path,compressed.blob,{cacheControl:"31536000",contentType:compressed.contentType,upsert:false});if(upload.error)throw upload.error;
 const oldPath=products.find(p=>p.id===productId)?.photo_path||null;
 const saved=await supabase.rpc("set_product_photo",{p_product_id:productId,p_photo_path:path});if(saved.error){await supabase.storage.from(PRODUCT_PHOTO_BUCKET).remove([path]);throw saved.error}
 const product=products.find(p=>p.id===productId);if(product)product.photo_path=path;if(oldPath&&oldPath!==path)await supabase.storage.from(PRODUCT_PHOTO_BUCKET).remove([oldPath]);return path;
};
const removeProductPhoto=async(productId:string)=>{
 if(demo)throw new Error("Photos are not available in demo mode.");if(!supabase)throw new Error("Supabase is not connected.");
 const product=products.find(p=>p.id===productId),oldPath=product?.photo_path||null;if(!oldPath)return;
 const saved=await supabase.rpc("set_product_photo",{p_product_id:productId,p_photo_path:null});if(saved.error)throw saved.error;if(product)product.photo_path=null;
 const removed=await supabase.storage.from(PRODUCT_PHOTO_BUCKET).remove([oldPath]);if(removed.error)notify("Photo removed from the product, but Storage cleanup failed. You can remove it again later.","error");
};
const downloadText=async(fileName:string,content:string)=>{
 try{
  if(Capacitor.isNativePlatform()){await ShopDownloads.saveTextToDownloads({fileName,content});notify("Saved to Android Downloads.","success");return}
 }catch(e){notify(e instanceof Error?e.message:"Android download failed; using browser download.","error")}
 const blob=new Blob([content],{type:"text/plain;charset=utf-8"}),url=URL.createObjectURL(blob),a=document.createElement("a");
 a.href=url;a.download=fileName;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
const localDate=(d=new Date())=>new Intl.DateTimeFormat("en-CA",{timeZone:settings.timezone||"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).format(d); const businessDate=(d=new Date())=>{const a=new Intl.DateTimeFormat("en-GB",{timeZone:settings.timezone||"Asia/Kolkata",hour:"2-digit",minute:"2-digit",hourCycle:"h23"}).formatToParts(d),hh=Number(a.find(x=>x.type==="hour")?.value||0),mm=Number(a.find(x=>x.type==="minute")?.value||0),r=String(settings.dashboard_reset_time||"00:00").split(":").map(Number),x=(hh<r[0]||(hh===r[0]&&mm<r[1]))?new Date(d.getTime()-86400000):d;return localDate(x)};
const fmt=(d:any)=>d?new Date(d).toLocaleString("en-IN",{dateStyle:"short",timeStyle:"short"}):"";
const notify=(m:string,t="info")=>{const x=document.createElement("div");x.className="toast "+t;x.textContent=m;document.body.appendChild(x);setTimeout(()=>x.remove(),2800)};
const errorMessage=(err:any)=>{
 const e=err?.error??err;
 if(e?.message)return String(e.message)+(e?.details?" — "+String(e.details):"")+(e?.hint?" — "+String(e.hint):"");
 if(typeof e==="string")return e;
 try{return JSON.stringify(e)}catch{return String(e)}
};
const readConn=()=>({url:localStorage.getItem(URL_KEY)||"",key:localStorage.getItem(KEY_KEY)||""});
const applyTheme=(theme:any)=>{
 const normalized=normalizeTheme(theme);
 document.documentElement.dataset.theme=normalized;
 try{localStorage.setItem(THEME_KEY,normalized)}catch{}
};
const currentTheme=()=>normalizeTheme(settings.theme||localStorage.getItem(THEME_KEY)||"current");
applyTheme(currentTheme());
const OAUTH_BACKEND_URL="https://shop-management-oauth.onrender.com";
const verifyAndUpdateDatabase=async()=>{
 if(demo)return {ok:true,updated:false,database_version:1,applied:[]};
 if(!supabase||!profile||profile.role!=="owner")throw new Error("Owner access is required.");
 const sessionResult=await supabase.auth.getSession();
 if(sessionResult.error||!sessionResult.data.session?.access_token)throw new Error("Your login session has expired. Please sign in again.");
 const c=readConn();
 if(!c.url||!c.key)throw new Error("Supabase connection details are missing.");
 const response=await fetch(OAUTH_BACKEND_URL+"/api/database/verify-and-update",{
  method:"POST",
  headers:{"Content-Type":"application/json"},
  body:JSON.stringify({supabase_url:c.url,publishable_key:c.key,access_token:sessionResult.data.session.access_token})
 });
 const data=await response.json().catch(()=>({}));
 if(!response.ok)throw new Error(String(data?.error||"Database update failed."));
 return data;
};
const connect=()=>{const c=readConn();if(c.url&&c.key){supabase=createClient(c.url,c.key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});return true}return false};
const daysAgo=(n:number,h=12)=>{const d=new Date();d.setDate(d.getDate()-n);d.setHours(h,15,0,0);return d.toISOString()};

function buildDemo(){
 const owner:Profile={id:"demo-owner",full_name:"Demo Owner",email:"owner@demo.shop",role:"owner",is_active:true,shop_id:"SHOP-DEMO0001"};
 const worker:Profile={id:"demo-worker",full_name:"Demo Worker",email:"worker@demo.shop",role:"worker",is_active:true,shop_id:"SHOP-DEMO0001"};
 const ps:Product[]=[
  {id:"p1",name:"Tata Salt 1kg",unit_type:"piece",current_stock_base:62,purchase_price_per_base_unit:24,selling_price_per_base_unit:30,low_stock_threshold_base:12,is_active:true},
  {id:"p2",name:"Aashirvaad Atta 5kg",unit_type:"piece",current_stock_base:28,purchase_price_per_base_unit:210,selling_price_per_base_unit:255,low_stock_threshold_base:8,is_active:true},
  {id:"p3",name:"Fortune Oil 1L",unit_type:"piece",current_stock_base:35,purchase_price_per_base_unit:112,selling_price_per_base_unit:135,low_stock_threshold_base:10,is_active:true},
  {id:"p4",name:"Toor Dal 1kg",unit_type:"piece",current_stock_base:11,purchase_price_per_base_unit:118,selling_price_per_base_unit:145,low_stock_threshold_base:12,is_active:true},
  {id:"p5",name:"Basmati Rice 5kg",unit_type:"piece",current_stock_base:9,purchase_price_per_base_unit:410,selling_price_per_base_unit:475,low_stock_threshold_base:8,is_active:true},
  {id:"p6",name:"Sugar 1kg",unit_type:"piece",current_stock_base:42,purchase_price_per_base_unit:42,selling_price_per_base_unit:50,low_stock_threshold_base:10,is_active:true},
  {id:"p7",name:"Moong Dal 1kg",unit_type:"weight",weight_price_unit:"kg",current_stock_base:18500,purchase_price_per_base_unit:110,selling_price_per_base_unit:135,low_stock_threshold_base:5000,is_active:true},
  {id:"p8",name:"Tea 250g",unit_type:"piece",current_stock_base:26,purchase_price_per_base_unit:92,selling_price_per_base_unit:120,low_stock_threshold_base:8,is_active:true}
 ];
 const cr=[{id:"c1",name:"Rahul Sharma",mobile:"9876543210"},{id:"c2",name:"Priya Traders",mobile:"9123456780"},{id:"c3",name:"Amit Verma",mobile:"9988776655"}];
 const db=[{id:"d1",name:"Sharma Wholesale",mobile:"9000000001"},{id:"d2",name:"City Distributors",mobile:"9000000002"}];
 const sales:AnyRow[]=[]; const pur:AnyRow[]=[]; const lg:AnyRow[]=[]; const dlg:AnyRow[]=[]; const ds:AnyRow[]=[]; const audits:AnyRow[]=[];
 const modes=["cash","upi","split","credit"];
 for(let i=0;i<365;i++){
   const date=new Date();date.setDate(date.getDate()-i);date.setHours(10+(i%8),20,0,0);
   const count=i<90?3+(i%5):0;
   let revenue=0,profit=0,cash=0,upi=0,credit=0;
   if(i<90){
     for(let j=0;j<count;j++){
       const p=ps[(i+j)%ps.length], qty=p.unit_type==="weight"?500+(j*250):1+(j%3);
       const total=saleTotal(p,qty,p.selling_price_per_base_unit);
       const gp=total-saleTotal(p,qty,p.purchase_price_per_base_unit);
       const mode=modes[(i+j)%modes.length];
       const ca=mode==="cash"?total:mode==="split"?Math.round(total*.45):0;
       const up=mode==="upi"?total:mode==="split"?total-ca:0;
       const crv=mode==="credit"?total:0;
       sales.push({id:"ds"+i+"-"+j,sold_at:date.toISOString(),product_id:p.id,product_name_snapshot:p.name,worker_id:j%2?worker.id:owner.id,quantity_base:p.unit_type==="weight"?qty:qty,quantity_display:qty,sold_unit:p.unit_type==="weight"?"grams":"piece",selling_price_per_base_unit:p.selling_price_per_base_unit,total_sale:total,gross_profit:gp,cash_amount:ca,upi_amount:up,credit_amount:crv,payment_mode:mode,voided:false,transaction_id:"tx"+i+"-"+j,products:{name:p.name},profiles:{full_name:j%2?"Demo Worker":"Demo Owner"}});
       revenue+=total;profit+=gp;cash+=ca;upi+=up;credit+=crv;
       if(crv>0)lg.push({id:"cl"+i+"-"+j,creditor_id:cr[(i+j)%cr.length].id,type:"credit_sale",amount:crv,payment_mode:"credit",created_at:date.toISOString(),worker_id:worker.id,profiles:{full_name:"Demo Worker"}});
     }
   } else {
     revenue=1500+(i%9)*275;profit=Math.round(revenue*.16);cash=Math.round(revenue*.42);upi=revenue-cash;credit=0;
   }
   ds.push({shop_id:owner.shop_id,business_date:localDate(date),total_transactions:count||Math.max(1,2+(i%3)),total_revenue:revenue,total_profit:profit,cash_sales:cash,upi_sales:upi,credit_sales:credit,cash_profit:Math.round(profit*(cash/Math.max(revenue,1))),upi_profit:Math.round(profit*(upi/Math.max(revenue,1))),credit_profit:Math.round(profit*(credit/Math.max(revenue,1))),creditor_amount:credit,purchase_cash:0,purchase_upi:0,purchase_credit:0,total_purchases:0,debtor_payment_cash:0,debtor_payment_upi:0,debtor_payment_total:0});
   if(i<365){
     const pd=new Date(date);pd.setHours(8,10,0,0);
     const p=ps[i%ps.length], qty=p.unit_type==="weight"?2500+(i%5)*500:10+(i%7), cost=saleTotal(p,qty,p.purchase_price_per_base_unit), mode=i%4===0?"credit":i%3===0?"split":i%2?"upi":"cash";
     const pc=mode==="cash"?cost:mode==="split"?cost*.5:0, pu=mode==="upi"?cost:mode==="split"?cost*.5:0, pcr=mode==="credit"?cost:0;
     const debtor=pcr>0?db[i%db.length]:null;
     pur.push({id:"dp"+i,product_id:p.id,product_name_snapshot:p.name,quantity_base:p.unit_type==="weight"?qty:qty,quantity_display:qty,purchase_unit:p.unit_type,purchase_price_per_base_unit:p.purchase_price_per_base_unit,total_cost:cost,purchased_at:pd.toISOString(),purchased_by:i%2?worker.id:owner.id,profiles:{full_name:i%2?"Demo Worker":"Demo Owner"},payment_mode:mode,cash_amount:pc,upi_amount:pu,credit_amount:pcr,credit_paid:0,pre_stock:false,supplier_name:pcr>0?debtor?.name:"",debtor_id:debtor?.id||null});
     if(pcr>0&&debtor)dlg.push({id:"dp-ledger-"+i,debtor_id:debtor.id,type:"credit_purchase",amount:pcr,payment_mode:"credit",cash_amount:0,upi_amount:0,created_at:pd.toISOString(),worker_id:i%2?worker.id:owner.id,profiles:{full_name:i%2?"Demo Worker":"Demo Owner"}});
     const row=ds[ds.length-1];row.purchase_cash=pc;row.purchase_upi=pu;row.purchase_credit=pcr;row.total_purchases=cost;
   }
   if(i<30) audits.push({id:"a"+i,created_at:date.toISOString(),actor_id:i%2?worker.id:owner.id,action:i%3?"sale_created":"purchase_created",entity_type:i%3?"sale":"purchase",profiles:{full_name:i%2?"Demo Worker":"Demo Owner"}});
 }
 // Add explicit pre-stock records: these never appear in Purchase History or financial purchase reports.
 for(let i=0;i<18;i++){const p=ps[i%ps.length];pur.push({id:"pre"+i,product_id:p.id,product_name_snapshot:p.name,quantity_base:20,quantity_display:20,purchase_unit:p.unit_type,purchase_price_per_base_unit:p.purchase_price_per_base_unit,total_cost:20*p.purchase_price_per_base_unit,purchased_at:daysAgo(20+i),purchased_by:owner.id,profiles:{full_name:"Demo Owner"},payment_mode:"pre_stock",cash_amount:0,upi_amount:0,credit_amount:0,pre_stock:true,supplier_name:"Opening Stock"});}
 for(const c of cr){lg.push({id:"pay"+c.id,creditor_id:c.id,type:"payment_received",amount:c.id==="c1"?1800:650,payment_mode:c.id==="c1"?"split":"upi",cash_amount:c.id==="c1"?900:0,upi_amount:c.id==="c1"?900:650,created_at:daysAgo(2),worker_id:owner.id,profiles:{full_name:"Demo Owner"}});}
 dlg.push({id:"dpay1",debtor_id:"d1",type:"payment_made",amount:900,payment_mode:"upi",cash_amount:0,upi_amount:900,created_at:daysAgo(1),worker_id:owner.id,profiles:{full_name:"Demo Owner"}});
 const paidDate=localDate(new Date(Date.now()-864e5));const paidRow=ds.find(x=>x.business_date===paidDate);if(paidRow){paidRow.debtor_payment_total=900;paidRow.debtor_payment_upi=900;}
 return {owner,worker,products:ps,sales,purchases:pur,creditors:cr,ledger:lg,debtors:db,debtorLedger:dlg,daily:ds,audit:audits,workers:[owner,worker],lifetime:{lifetime_sales:ds.reduce((a,x)=>a+Number(x.total_revenue||0),0),lifetime_purchases:pur.reduce((a,x)=>a+Number(x.total_cost||0),0),lifetime_profit:ds.reduce((a,x)=>a+Number(x.total_profit||0),0)}};
}

let demoData:ReturnType<typeof buildDemo>|null=null;
function initDemo(){if(!demoData)demoData=buildDemo();const d=demoData;products=d.products;sales=d.sales;purchases=d.purchases;creditors=d.creditors;ledger=d.ledger;debtors=d.debtors;debtorLedger=d.debtorLedger;daily=d.daily;auditRows=d.audit;returnsRows=[];workersRows=d.workers;lifetime=d.lifetime;settings={shop_name:"Demo Grocery Store",currency:"INR",timezone:"Asia/Kolkata",workers_can_modify_selling_price:true,allow_below_cost_sales:true,allow_zero_price_sales:true,dashboard_reset_time:"00:00",theme:"current"};profile=d.owner;demo=true;demoReady=true}
function qBalance(id:string){return ledger.filter(x=>x.creditor_id===id).reduce((a,x)=>a+(x.type==="credit_sale"||x.type==="adjustment"?Number(x.amount):x.type==="payment_received"?-Number(x.amount):0),0)}
function dBalance(id:string){return debtorLedger.filter(x=>x.debtor_id===id).reduce((a,x)=>a+(x.type==="credit_purchase"||x.type==="adjustment"?Number(x.amount):x.type==="payment_made"?-Number(x.amount):0),0)}
function currentSales(){const today=businessDate();return sales.filter(s=>!s.voided&&businessDate(new Date(s.sold_at))===today)}
function currentStats(){const a=currentSales(),today=businessDate(),r=returnsRows.filter(x=>x.return_type==="sale"&&businessDate(new Date(x.returned_at))===today);const rr=r.reduce((z,x)=>z+Number(x.total_amount||0),0),rp=r.reduce((z,x)=>z+Number(x.profit_impact||0),0),rc=r.reduce((z,x)=>z+Number(x.cash_amount||0),0),ru=r.reduce((z,x)=>z+Number(x.upi_amount||0),0),rcr=r.reduce((z,x)=>z+Number(x.credit_amount||0),0);const cash=a.reduce((x,y)=>x+Number(y.cash_amount||0),0)-rc;const upi=a.reduce((x,y)=>x+Number(y.upi_amount||0),0)-ru;const credit=a.reduce((x,y)=>x+saleCreditAmount(y),0)-rcr;const sales=a.reduce((x,y)=>x+Number(y.total_sale||0),0)-rr;return {tx:new Set(a.map(x=>x.transaction_id||x.id)).size,sales,profit:a.reduce((x,y)=>x+Number(y.gross_profit||0),0)+rp,cash,upi,credit}}

async function loadData(){
 if(demo){if(!demoReady)initDemo();applyTheme(settings.theme);return}
 if(!supabase||!profile)return;
 const [set,p,s,q,c,l,db,dl,df,life,au,rr,wr]=await Promise.all([
  supabase.from("shop_settings").select("*").limit(1).maybeSingle(),
  supabase.from("products").select("*").eq("is_active",true).order("name"),
  supabase.from("sales").select("*,products(name),profiles:worker_id(full_name)").order("sold_at",{ascending:false}).limit(1000),
  supabase.from("inventory_purchases").select("*,profiles:purchased_by(full_name)").order("purchased_at",{ascending:false}).limit(1000),
  supabase.from("creditors").select("*").order("name"),
  supabase.from("credit_ledger").select("*,profiles:worker_id(full_name)").order("created_at",{ascending:false}).limit(2000),
  supabase.from("debtors").select("*").order("name"),
  supabase.from("debtor_ledger").select("*,profiles:worker_id(full_name)").order("created_at",{ascending:false}).limit(2000),
  supabase.from("daily_financial_summaries").select("*").order("business_date",{ascending:false}).limit(400),
  supabase.from("lifetime_financial_summaries").select("*").limit(1).maybeSingle(),
  supabase.from("audit_logs").select("*,profiles:actor_id(full_name)").order("created_at",{ascending:false}).limit(1000),
  supabase.from("returns").select("*,products(name),profiles:returned_by(full_name)").order("returned_at",{ascending:false}).limit(1000),
  supabase.from("profiles").select("*").order("full_name")
 ]);
 if(set.data)settings={...settings,...set.data,theme:normalizeTheme(set.data.theme||localStorage.getItem(THEME_KEY)||"current")};applyTheme(settings.theme);
 products=p.data||[];sales=s.data||[];purchases=q.data||[];creditors=c.data||[];ledger=l.data||[];debtors=db.data||[];debtorLedger=dl.data||[];daily=df.data||[];lifetime=life.data||{lifetime_sales:0,lifetime_purchases:0,lifetime_profit:0};auditRows=au.data||[];returnsRows=rr?.data||[];workersRows=(wr.data||[]).map((x:any)=>({...x,role:x.role as Role}));
}

async function setupRealtime(){
 if(demo||!supabase||!profile)return;
 if(realtimeChannel)await supabase.removeChannel(realtimeChannel);
 if(realtimeRefreshTimer){window.clearInterval(realtimeRefreshTimer);realtimeRefreshTimer=undefined}
 const tables=["sales","inventory_purchases","credit_ledger","debtor_ledger","returns","products","daily_financial_summaries","lifetime_financial_summaries"];
 realtimeChannel=supabase.channel("shop-management-live-"+profile.id);
 for(const table of tables){
  realtimeChannel.on("postgres_changes",{event:"*",schema:"public",table},async()=>{
   await loadData();
   if(activeTab==="today"||activeTab==="reports"||activeTab==="dashboard")render();
  });
 }
 realtimeChannel.subscribe();
 realtimeRefreshTimer=window.setInterval(async()=>{
  if(!profile||demo||!supabase)return;
  if(activeTab==="today"||activeTab==="reports"){await loadData();render()}
 },5000);
}

function shell(title:string){
 const owner=profile?.role==="owner";
 const allNav:[string,string,string][]=[
  ["dashboard","Home","home"],["sale","Sale","shopping-cart"],["stock","Products","package"],
  ["cart","Cart","shopping-cart"],["returns","Returns","rotate-ccw"],["creditors","Creditors","wallet"],
  ["debtors","Debtors","wallet-cards"],["history","History","history"],["today","Today Stats","calendar-days"],
  ["reports","Reports","chart-no-axes-combined"],["workers","Workers","users"],["audit","Audit","clipboard-check"],["settings","Settings","settings"]
 ];
 const nav=allNav.filter(x=>owner||!["today","reports","workers","audit","settings"].includes(x[0]));
 const visible=["dashboard","sale","stock","more"];
 const icon=(name:string)=>'<span class="ui-icon ui-icon-'+name+'" aria-hidden="true"></span>';
 const visibleButtons=visible.map(id=>{
   if(id==="more")return '<button id="moreNav" type="button" class="more-nav '+(activeTab==="more"?"active":"")+'">'+icon("more-horizontal")+'<span>More</span></button>';
   const item=nav.find(x=>x[0]===id)!;
   return '<button data-nav="'+item[0]+'" class="'+(activeTab===item[0]?"active":"")+'">'+icon(item[2])+'<span>'+esc(item[1])+'</span></button>';
 }).join("");
 return '<div class="app-shell"><header><div class="header-left">'+(activeTab!=="dashboard"?'<button id="uiBack" type="button" class="header-back" aria-label="Back">‹</button>':"")+'<div class="header-brand"><span class="brand-mark">'+icon("store")+'</span><div><b>'+esc(settings.shop_name)+'</b><span class="muted">'+esc(title==="dashboard"?"Owner Dashboard":title==="sale"?"Sale":title==="more"?"More":title.replace(/(^|_)/g," "))+'</span></div></div></div><button id="logout" class="header-icon-btn" type="button" aria-label="Sign out" title="Sign out">'+icon("log-out")+'</button></header><main><div id="view"></div></main><nav class="bottom-nav">'+visibleButtons+'</nav></div>';
}

const normalizeSearchText=(value:any)=>String(value??"").toLowerCase().replace(/[^a-z0-9]+/g,"");
const searchMatches=(haystack:any,query:string)=>{
 const raw=String(query||"").trim().toLowerCase();
 if(!raw)return true;
 const compact=normalizeSearchText(raw);
 const hay=normalizeSearchText(haystack);
 if(compact&&hay.includes(compact))return true;
 const parts=raw.split(/\s+/).map(x=>normalizeSearchText(x)).filter(Boolean);
 return parts.length>0&&parts.every(x=>hay.includes(x));
};
let pendingStockSearch="";
function homeSearchItems(){
 const owner=profile?.role==="owner";
 const items:{label:string;keywords:string;tab:string;action?:string;description:string}[]=[
  {label:"Home",keywords:"home dashboard today overview",tab:"dashboard",description:"Open dashboard"},
  {label:"Add Sale",keywords:"sale sell selling new transaction",tab:"sale",description:"Create a sale"},
  {label:"Cart",keywords:"cart checkout multi item sale",tab:"cart",description:"Open cart"},
  {label:"Stock",keywords:"stock products inventory item items",tab:"stock",description:"View stock"},
  {label:"Add Product",keywords:"product products new add create item",tab:"stock",action:"addProduct",description:"Add a product"},
  {label:"Purchase",keywords:"purchase buy buying stock entry inventory",tab:"stock",action:"purchase",description:"Add a purchase"},
  {label:"Returns",keywords:"return refund purchase sale",tab:"returns",description:"Open returns"},
  {label:"Creditors",keywords:"creditor supplier suppliers payable credit payment",tab:"creditors",description:"Open creditors"},
  {label:"Debtors",keywords:"debtor customer customers receivable credit payment",tab:"debtors",description:"Open debtors"},
  {label:"History",keywords:"history transactions sales purchases returns records",tab:"history",description:"View transaction history"}
 ];
 if(owner){
  items.push(
   {label:"Today Stats",keywords:"today stats statistics daily closing day end summary",tab:"today",description:"View today statistics"},
   {label:"Reports",keywords:"report reports profit revenue financial date wise",tab:"reports",description:"Open reports"},
   {label:"Workers",keywords:"worker workers staff employees",tab:"workers",description:"Manage workers"},
   {label:"Audit",keywords:"audit logs activity security records",tab:"audit",description:"View audit logs"},
   {label:"Settings",keywords:"settings configuration shop preferences",tab:"settings",description:"Open settings"}
  );
 }
 return items;
}
function openHomeSearchItem(item:{tab:string;action?:string}){
 pendingStockSearch="";
 if(item.action==="addProduct"){activeTab="stock";lowStockOnly=false;render();setTimeout(()=>productForm(),0);return}
 if(item.action==="purchase"){activeTab="stock";lowStockOnly=false;render();setTimeout(()=>purchaseForm(),0);return}
 activeTab=item.tab;
 if(item.tab!=="stock")lowStockOnly=false;
 render();
}

function dashboardSummaryRows(kind:string){
 const today=currentSales();
 if(kind==="total-sales")return today.map(x=>({name:String(x.product_name_snapshot||x.products?.name||"Product unavailable"),amount:money(x.total_sale)}));
 if(kind==="total-profit")return today.map(x=>({name:String(x.product_name_snapshot||x.products?.name||"Product unavailable"),amount:money(x.gross_profit)}));
 if(kind==="cash"){
  return today.filter(x=>Number(x.cash_amount||0)>0).map(x=>{
   const total=Math.max(0,Number(x.total_sale||0)),cash=Number(x.cash_amount||0),profit=Number(x.gross_profit||0)*(total?cash/total:0);
   return {name:String(x.product_name_snapshot||x.products?.name||"Product unavailable"),amount:money(cash),profit:money(profit)};
  });
 }
 if(kind==="upi"){
  return today.filter(x=>Number(x.upi_amount||0)>0).map(x=>{
   const total=Math.max(0,Number(x.total_sale||0)),upi=Number(x.upi_amount||0),profit=Number(x.gross_profit||0)*(total?upi/total:0);
   return {name:String(x.product_name_snapshot||x.products?.name||"Product unavailable"),amount:money(upi),profit:money(profit)};
  });
 }
 if(kind==="low-stock"){
  return products.filter(p=>Number(p.current_stock_base)<=Number(p.low_stock_threshold_base))
   .map(p=>({name:p.name,amount:String(p.current_stock_base)+" "+(p.unit_type==="piece"?"pcs":"g")+" / limit "+String(p.low_stock_threshold_base)+(p.unit_type==="piece"?" pcs":" g")}));
 }
 if(kind==="pending-dues"){
  return creditors.map(c=>({name:String(c.name),amount:money(ledger.filter(x=>x.creditor_id===c.id).reduce((a,x)=>a+(x.type==="credit_sale"||x.type==="adjustment"?Number(x.amount||0):x.type==="payment_received"?-Number(x.amount||0):0),0))}))
   .filter(x=>Number(x.amount.replace(/[^0-9.-]/g,""))>0);
 }
 return [];
}
function dashboardSummaryTitle(kind:string){
 return ({
  "total-sales":"Total Sales",
  "total-profit":"Total Profit",
  "cash":"Cash Sales",
  "upi":"UPI Sales",
  "low-stock":"Low Stock Products",
  "pending-dues":"Pending Dues"
 } as Record<string,string>)[kind]||"Summary";
}
function dashboardSummaryMarkup(kind:string){
 if(!kind)return "";
 const title=dashboardSummaryTitle(kind),rows=dashboardSummaryRows(kind);
 let content="";
 if(!rows.length){
  content='<div class="dashboard-summary-empty">No '+esc(title.toLowerCase())+' to show.</div>';
 }else if(kind==="cash"||kind==="upi"){
  content='<div class="dashboard-summary-head"><span>Sale</span><span>Amount</span><span>Profit</span></div>'+rows.map((x:any)=>'<div class="dashboard-summary-row"><b>'+esc(x.name)+'</b><span>'+esc(x.amount)+'</span><span>'+esc(x.profit||"")+'</span></div>').join("");
 }else{
  content='<div class="dashboard-summary-head"><span>Product / Account</span><span>'+esc(kind==="low-stock"?"Stock":"Amount")+'</span></div>'+rows.map(x=>'<div class="dashboard-summary-row"><b>'+esc(x.name)+'</b><span>'+esc(x.amount)+'</span></div>').join("");
 }
 return '<section id="dashboardMetricSummary" class="panel dashboard-summary-inline"><div class="dashboard-summary-headbar"><div><h3 id="dashboardMetricSummaryTitle">'+esc(title)+'</h3><small>Records belonging to this dashboard metric.</small></div><button id="dashboardMetricSummaryClose" type="button" class="ghost" aria-label="Close">Close</button></div><div id="dashboardMetricSummaryContent" class="dashboard-summary-content">'+content+'</div></section>';
}
function showDashboardSummary(kind:string){
 dashboardSummaryKind=kind;
 render();
}
function bindDashboardMetricSummaries(){
 document.querySelectorAll<HTMLButtonElement>("[data-dashboard-summary]").forEach(btn=>{
  btn.addEventListener("click",()=>showDashboardSummary(String(btn.dataset.dashboardSummary||"")));
 });
 document.querySelector("#dashboardMetricSummaryClose")?.addEventListener("click",()=>{
  dashboardSummaryKind="";
  render();
 });
}
function moreView(){
 const owner=profile?.role==="owner";
 const items:[string,string,string,string][]=[
  ["sale","Sale","shopping-cart","Create a sale"],
  ["cart","Cart","shopping-cart","Open cart"],
  ["stock","Products","package","View and manage stock"],
  ["returns","Returns","rotate-ccw","Handle sale and purchase returns"],
  ["creditors","Creditors","wallet","Manage creditor accounts"],
  ["debtors","Debtors","wallet-cards","Manage debtor accounts"],
  ["history","History","history","View transaction history"]
 ];
 if(owner){
  items.push(["today","Today Stats","calendar-days","View daily statistics"],["reports","Reports","chart-no-axes-combined","View reports"],["workers","Workers","users","Manage workers"],["audit","Audit","clipboard-check","View audit logs"],["settings","Settings","settings","Shop settings"]);
 }
 const icon=(name:string)=>'<span class="ui-icon ui-icon-'+name+'" aria-hidden="true"></span>';
 return '<section class="page more-page"><div class="page-head"><div><h2>More</h2><p class="muted">All shop management functions are part of the app.</p></div></div><div class="panel more-page-menu"><div class="more-menu">'+items.map(x=>'<button type="button" data-nav="'+x[0]+'" class="more-menu-item">'+icon(x[2])+'<span><b>'+esc(x[1])+'</b><small>'+esc(x[3])+'</small></span><span class="chevron">›</span></button>').join("")+'</div></div></section>';
}
function dashboard(){
 const s=currentStats(),low=products.filter(p=>Number(p.current_stock_base)<=Number(p.low_stock_threshold_base));
 const pending=creditors.reduce((a,c)=>a+ledger.filter(x=>x.creditor_id===c.id&&x.type==="credit_sale").reduce((v,x)=>v+Number(x.amount||0),0),0);
 const activity:{type:string;title:string;subtitle:string;amount:number;date:any;mode?:string;product_id?:string}[]=[];
 const activityProductName=(row:any)=>{
  const id=row.product_id||row.products?.id;
  const current=id?products.find(p=>p.id===id)?.name:"";
  const snapshot=String(row.product_name_snapshot||"").trim();
  return snapshot&&snapshot.toLowerCase()!=="deleted product" ? snapshot : (current||String(row.products?.name||"Product unavailable"));
 };
 sales.filter(x=>!x.voided).forEach(x=>activity.push({type:"Sale",title:activityProductName(x),subtitle:(x.quantity_display?String(x.quantity_display)+" · ":"")+"Sale · "+String(x.payment_mode||"cash").toUpperCase(),amount:Number(x.total_sale||0),date:x.sold_at,mode:String(x.payment_mode||"cash"),product_id:x.product_id||x.products?.id}));
 purchases.filter(x=>!x.pre_stock).forEach(x=>activity.push({type:"Purchase",title:activityProductName(x),subtitle:(x.quantity_display?String(x.quantity_display)+" · ":"")+"Purchase · "+String(x.payment_mode||"cash").toUpperCase(),amount:Number(x.total_cost||0),date:x.purchased_at,mode:String(x.payment_mode||"cash"),product_id:x.product_id||x.products?.id}));
 returnsRows.forEach(x=>activity.push({type:"Return",title:activityProductName(x),subtitle:(String(x.return_type||"return").replace(/_/g," ")+" · "+String(x.payment_mode||"cash")).toUpperCase(),amount:Number(x.total_amount||0),date:x.returned_at,mode:String(x.payment_mode||"cash"),product_id:x.product_id||x.products?.id}));
 ledger.filter(x=>x.type==="payment_received").forEach(x=>{const cr=creditors.find(c=>c.id===x.creditor_id);activity.push({type:"Credit payment",title:String(cr?.name||"Creditor"),subtitle:"Credit payment · "+String(x.payment_mode||"cash").toUpperCase(),amount:Number(x.amount||0),date:x.created_at,mode:String(x.payment_mode||"cash")})});
 debtorLedger.filter(x=>x.type==="payment_made").forEach(x=>{const d=debtors.find(v=>v.id===x.debtor_id);activity.push({type:"Debtor payment",title:String(d?.name||"Debtor"),subtitle:"Debtor payment · "+String(x.payment_mode||"cash").toUpperCase(),amount:Number(x.amount||0),date:x.created_at,mode:String(x.payment_mode||"cash")})});
 activity.sort((a,b)=>new Date(b.date||0).getTime()-new Date(a.date||0).getTime());
 const recent=activity.slice(0,8);
 const recentActivityIcon=(x:any)=>{
  const p=x.product_id?products.find(v=>v.id===x.product_id):null;
  const photo=productPhotoUrl(p?.photo_path);
  return photo
   ? '<span class="recent-activity-icon recent-activity-product-photo"><img src="'+esc(photo)+'" alt="" loading="lazy"></span>'
   : '<span class="recent-activity-icon recent-activity-'+x.type.toLowerCase().replace(/[^a-z]+/g,"-")+'">'+iconForPayment(x.mode||"cash")+'</span>';
 };
 return '<section class="page dashboard-page"><div class="page-head"><div><h2>Today</h2><p class="muted">'+esc(localDate())+'</p></div><button id="refresh" type="button" class="ghost refresh-action" aria-label="Refresh data">↻</button></div><div class="panel home-search-panel"><div class="section-head"><div><h3>Search</h3><small class="muted">Find a menu, action, or product shortcut.</small></div></div><div class="search-row home-search-row"><input id="homeSearch" type="search" autocomplete="off" placeholder="Search products, sales, stock, reports..."><button id="homeSearchBtn" type="button" class="ghost">Search</button></div><div id="homeSearchResults" class="home-search-results"></div></div><div class="metrics dashboard-metrics">'+m("Total Sales",money(s.sales))+m("Total Profit",money(s.profit))+m("Cash",money(s.cash))+m("UPI",money(s.upi))+m("Low Stock",String(low.length)+" items")+m("Pending Dues",money(pending))+'</div>'+dashboardSummaryMarkup(dashboardSummaryKind)+'<div class="section-head dashboard-section-title"><h3>Quick Actions</h3></div><div class="quick-grid dashboard-quick"><button data-nav="sale" class="quick-action quick-sale"><span class="quick-icon ui-icon ui-icon-plus"></span><b>Add Sale</b></button><button data-nav="cart" class="quick-action quick-cart"><span class="quick-icon ui-icon ui-icon-shopping-cart"></span><b>Cart</b></button><button data-nav="stock" class="quick-action quick-stock"><span class="quick-icon ui-icon ui-icon-package"></span><b>Stock</b></button><button data-nav="creditors" class="quick-action quick-creditor"><span class="quick-icon ui-icon ui-icon-wallet"></span><b>Creditor</b></button></div><div class="panel recent-panel"><div class="section-head"><h3>Recent Activity</h3><button type="button" data-nav="history" class="link-btn">History</button></div><div class="recent-activity-list">'+(recent.map((x,i)=>{const typeClass=x.type.toLowerCase().replace(/[^a-z]+/g,"-");return '<div class="recent-activity-row">'+recentActivityIcon(x)+'<div class="recent-activity-main"><b>'+esc(x.title)+'</b><small>'+esc(x.subtitle)+" · "+esc(fmt(x.date))+'</small></div><div class="recent-activity-total"><b>'+money(x.amount)+'</b><small>'+esc(x.type)+'</small></div></div>';}).join("")||'<div class="empty-state">No recent activity.</div>')+'</div></div></section>';
}


function sale(){
 return '<section class="page sale-page"><div class="page-head"><div><h2>Add Sale</h2><p class="muted">Search and select any product.</p></div></div><div class="panel"><div class="search-row"><input id="saleSearch" placeholder="Search product..."><button id="saleSearchBtn" class="ghost">Search</button></div><div id="saleProducts" class="product-grid"></div><form id="saleForm" class="form-grid"><label>Product<select name="product" required>'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+'</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min="0" step="any" value="1" required></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label><label>Selling price<input name="price" type="number" step="any" min="0" required></label><label>Payment<select name="mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label><label id="cashBox" class="hidden">Cash<input name="cash" type="number" step="any" min="0" value="0"></label><label id="upiBox" class="hidden">UPI<input name="upi" type="number" step="any" min="0" value="0"></label><label id="creditBox" class="hidden">Credit<input name="credit" type="number" step="any" min="0" value="0"></label><label id="creditorBox" class="hidden">Creditor<select name="creditor"><option value="">Select creditor</option>'+creditors.map(c=>'<option value="'+c.id+'">'+esc(c.name)+' — '+esc(c.mobile)+'</option>').join("")+'<option value="__new__">＋ New Creditor</option></select></label><div class="full notice" id="saleTotal">Total: ₹0.00</div><button class="primary full">Complete Sale</button></form></div></section>';
}

function cart(){
 const total=cartItems.reduce((a,x)=>{const p=products.find(p=>p.id===x.product_id);return a+saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0)},0);
 return '<section class="page cart-page"><div class="page-head"><h2>Cart</h2><span class="badge">'+cartItems.length+' item(s)</span></div><div class="panel"><div class="search-row"><input id="cartSearch" placeholder="Search product to add..."><button id="cartSearchBtn" class="ghost">Search</button></div><div id="cartProducts" class="product-grid"></div><form id="cartAdd" class="form-grid"><label>Product<select name="product">'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+' — '+p.current_stock_base+' available</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min="0" step="any" value="1"></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label><label id="cartSellingLabel">Selling price<input name="price" type="number" step="any" min="0"></label><div class="full notice" id="cartPreview">Preview: select a product</div><button class="primary full">Add to Cart</button></form><div class="notice">Cart total: <b>'+money(total)+'</b></div>'+ (cartItems.length?'<div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty</th><th>Total</th><th></th></tr></thead><tbody>'+cartItems.map((x,i)=>{const p=products.find(p=>p.id===x.product_id);return '<tr><td>'+esc(x.product_name_snapshot||p?.name||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>'+money(saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0))+'</td><td><button class="smallbtn edit-cart" data-i="'+i+'">Edit</button> <button class="smallbtn delete-cart" data-i="'+i+'">Delete</button></td></tr>'}).join("")+'</tbody></table></div>':"")+'<div class="panel"><form id="cartPay" class="form-grid"><label>Payment<select name="mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label><label>Cash<input name="cash" type="number" min="0" step="any" value="'+total.toFixed(2)+'"></label><label>UPI<input name="upi" type="number" min="0" step="any" value="0"></label><label>Credit<input name="credit" type="number" min="0" step="any" value="0"></label><label>Creditor<select name="creditor"><option value="">Select creditor</option>'+creditors.map(c=>'<option value="'+c.id+'">'+esc(c.name)+'</option>').join("")+'<option value="__new__">＋ New Creditor</option></select></label><button class="primary full" '+(cartItems.length?"":"disabled")+'>Confirm Cart Sale</button></form></div></div></section>';
}async function saveSale(item:any,mode:string,cash:number,upi:number,credit:number,creditorId:string|null){
 if(demo){const p=products.find(x=>x.id===item.product_id);if(!p)throw new Error("Product not found");const total=saleTotal(p,Number(item.quantity_base)||0,Number(item.selling_price_per_base_unit)||0);sales.unshift({...item,id:"demo-sale-"+Date.now(),sold_at:new Date().toISOString(),worker_id:profile!.id,total_sale:total,gross_profit:total-saleTotal(p,Number(item.quantity_base)||0,Number(p.purchase_price_per_base_unit)||0),cash_amount:cash,upi_amount:upi,credit_amount:credit,payment_mode:mode,voided:false,transaction_id:"demo-tx-"+Date.now(),products:{name:p.name},profiles:{full_name:profile!.full_name}});p.current_stock_base-=item.quantity_base;if(credit>0&&creditorId)ledger.unshift({id:"demo-ledger-"+Date.now(),creditor_id:creditorId,type:"credit_sale",amount:credit,payment_mode:mode,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});return}
 if(mode==="cash"||mode==="upi"||mode==="split"){
  const r=await supabase!.rpc("record_sale",{p_product_id:item.product_id,p_worker_id:profile!.id,p_quantity_base:item.quantity_base,p_quantity_display:item.quantity_display,p_sold_unit:item.sold_unit,p_selling_price_per_base_unit:item.selling_price_per_base_unit,p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi});
  if(r.error)throw r.error;
  return;
 }
 const r=await supabase!.rpc("complete_cart_sale",{p_worker_id:profile!.id,p_items:[item],p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi,p_credit_amount:credit,p_creditor_id:creditorId});
 if(r.error)throw r.error;
}

function stock(){
 const owner=profile?.role==="owner";
 const title=lowStockOnly?"Low Stock":"Stock";
 const subtitle=lowStockOnly?"Products at or below their low-stock limit.":"Current stock and purchase actions.";
 return '<section class="page stock-page"><div class="page-head"><div><h2>'+title+'</h2><p class="muted">'+subtitle+'</p></div><div class="action-row">'+(lowStockOnly?'<button id="showAllStock" class="ghost">Show All Stock</button>':"")+(owner?'<button id="addProduct" class="ghost">＋ Add Product</button>':"")+'<button id="addPurchase" class="primary">＋ Purchase</button></div></div><div id="stockForm"></div><div class="panel stock-list-panel"><div class="search-row stock-search-row"><input id="stockSearch" type="search" autocomplete="off" placeholder="Search product name or number..."><button id="stockSearchBtn" type="button" class="ghost">Search</button></div><div class="stock-search-status" id="stockSearchStatus"></div><div class="table-wrap"><table><thead><tr><th>Product</th><th>Current</th><th>Buy</th><th>Sell</th>'+(owner?'<th>Actions</th>':"")+'</tr></thead><tbody>'+products.filter(p=>!lowStockOnly||Number(p.current_stock_base)<=Number(p.low_stock_threshold_base)).map(p=>'<tr class="stock-product-row" data-search="'+esc([p.name,p.id,(p as any).sku,(p as any).barcode,(p as any).product_code].filter(Boolean).join(" ").toLowerCase())+'"><td><div class="stock-product-cell">'+productPhotoMarkup(p,true)+'<span>'+esc(p.name)+'</span></div></td><td>'+p.current_stock_base+' '+(p.unit_type==="piece"?"pcs":"g")+'</td><td>'+money(p.purchase_price_per_base_unit)+(p.unit_type==="weight"?((p.weight_price_unit||"kg")==="kg"?"/kg":"/g"):"")+'</td><td>'+money(p.selling_price_per_base_unit)+(p.unit_type==="weight"?((p.weight_price_unit||"kg")==="kg"?"/kg":"/g"):"")+'</td>'+(owner?'<td><button class="smallbtn edit-product" data-id="'+p.id+'">Edit</button> <button class="smallbtn danger delete-product" data-id="'+p.id+'">Delete</button></td>':"")+'</tr>').join("")+'</tbody></table></div></div></section>';
}
function productEditForm(productId:string){
 const p=products.find(x=>x.id===productId);if(!p)return notify("Product not found.","error");
 const h=document.querySelector("#stockForm")!,priceUnit=p.unit_type==="weight"?(p.weight_price_unit||"kg"):"piece";
 h.innerHTML='<div class="panel"><h3>Edit Product</h3><form id="productEditForm" class="form-grid"><label>Name<input name="name" value="'+esc(p.name)+'" required></label><label>Price unit<select name="weightUnit" '+(p.unit_type==="piece"?"disabled":"")+'><option value="kg" '+(priceUnit==="kg"?"selected":"")+'>kg (price per kg)</option><option value="grams" '+(priceUnit==="grams"?"selected":"")+'>grams (price per gram)</option></select></label><label>Purchase price<input name="purchase" type="number" min="0" step="any" value="'+esc(p.purchase_price_per_base_unit)+'" required></label><label>Selling price<input name="sale" type="number" min="0" step="any" value="'+esc(p.selling_price_per_base_unit)+'" required></label><label>Low stock limit<input name="low" type="number" min="0" step="any" value="'+esc(p.low_stock_threshold_base)+'" required></label><div class="product-photo-editor full" id="editProductPhoto"><div class="product-photo-stage">'+productPhotoMarkup(p)+'</div><div class="photo-actions"><label class="smallbtn photo-pick">Change Photo<input id="editProductPhotoInput" type="file" accept="image/*" hidden></label><button id="editProductPhotoRemove" type="button" class="smallbtn danger" '+(p.photo_path?"":"disabled")+'>Remove Photo</button></div><small class="muted">Photo is compressed before upload.</small></div><div class="action-row full"><button class="primary">Save Changes</button><button id="cancelProductEdit" type="button" class="ghost">Cancel</button></div></form></div>';
 const f=document.querySelector<HTMLFormElement>("#productEditForm")!;
 const editPhotoInput=document.querySelector("#editProductPhotoInput") as HTMLInputElement,editPhotoRemove=document.querySelector("#editProductPhotoRemove") as HTMLButtonElement;
 editPhotoInput.addEventListener("change",async()=>{const file=editPhotoInput.files?.[0];if(!file)return;try{editPhotoRemove.disabled=true;await uploadProductPhoto(p.id,file);document.querySelector("#editProductPhoto .product-photo-stage")!.innerHTML=productPhotoMarkup(p);editPhotoRemove.disabled=false;notify("Product photo updated.","success")}catch(err){notify(errorMessage(err),"error")}finally{editPhotoInput.value=""}});
 editPhotoRemove.addEventListener("click",async()=>{if(!p.photo_path)return;if(!window.confirm("Remove this product photo?"))return;try{await removeProductPhoto(p.id);document.querySelector("#editProductPhoto .product-photo-stage")!.innerHTML=productPhotoMarkup(p);editPhotoRemove.disabled=true;notify("Product photo removed.","success")}catch(err){notify(errorMessage(err),"error")}});
 const weightUnitEl=f.elements.namedItem("weightUnit") as HTMLSelectElement,buyEl=f.elements.namedItem("purchase") as HTMLInputElement,sellEl=f.elements.namedItem("sale") as HTMLInputElement;
 weightUnitEl?.addEventListener("change",()=>{if(p.unit_type!=="weight")return;const oldUnit=p.weight_price_unit||"kg",nextUnit=weightUnitEl.value;if(oldUnit===nextUnit)return;const factor=oldUnit==="kg"&&nextUnit==="grams"?1/1000:1000;buyEl.value=(Number(buyEl.value||0)*factor).toFixed(4);sellEl.value=(Number(sellEl.value||0)*factor).toFixed(4)});
 document.querySelector("#cancelProductEdit")?.addEventListener("click",()=>{h.innerHTML=""});
 f.addEventListener("submit",async e=>{
  e.preventDefault();
  const fd=new FormData(f),name=String(fd.get("name")||"").trim(),buy=Number(fd.get("purchase")),sell=Number(fd.get("sale")),low=Number(fd.get("low")),weightUnit=p.unit_type==="weight"?(String(fd.get("weightUnit")||"kg") as "kg"|"grams"):"kg";
  if(!name||!Number.isFinite(buy)||buy<0||!Number.isFinite(sell)||sell<0||!Number.isFinite(low)||low<0||!["kg","grams"].includes(weightUnit))return notify("Enter valid product details.","error");
  try{
   if(demo){p.name=name;p.purchase_price_per_base_unit=buy;p.selling_price_per_base_unit=sell;p.low_stock_threshold_base=low;p.weight_price_unit=p.unit_type==="weight"?weightUnit:undefined}
   else{const r=await supabase!.rpc("update_product_with_price_unit",{p_product_id:p.id,p_name:name,p_purchase_price:buy,p_selling_price:sell,p_low_stock_threshold_base:low,p_weight_price_unit:weightUnit});if(r.error)throw r.error;await loadData()}
   notify("Product updated.","success");render();
  }catch(err){notify(errorMessage(err),"error")}
 });
}
function bindStockActions(){
 document.querySelectorAll<HTMLButtonElement>(".edit-product").forEach(b=>b.addEventListener("click",()=>productEditForm(String(b.dataset.id||""))));
 document.querySelectorAll<HTMLButtonElement>(".delete-product").forEach(b=>b.addEventListener("click",async()=>{
  const id=String(b.dataset.id||""),p=products.find(x=>x.id===id);
  if(!p)return;
  if(!window.confirm("Delete product \"" + p.name + "\"? This removes it from active Stock but preserves history."))return;
  try{
   if(demo){p.is_active=false;products=products.filter(x=>x.id!==id)}
   else{const r=await supabase!.rpc("delete_product",{p_product_id:id});if(r.error)throw r.error;await loadData()}
   notify("Product deleted from active stock. Historical records were preserved.","success");render();
  }catch(err){notify(errorMessage(err),"error")}
 }));
}
function bindSale(){
 const f=document.querySelector<HTMLFormElement>("#saleForm")!,sel=f.elements.namedItem("product") as HTMLSelectElement,qty=f.elements.namedItem("qty") as HTMLInputElement,price=f.elements.namedItem("price") as HTMLInputElement,unit=f.elements.namedItem("unit") as HTMLSelectElement,mode=f.elements.namedItem("mode") as HTMLSelectElement;
 const priceLabel=f.querySelector("label:nth-of-type(4)") as HTMLElement; const update=(resetPrice=true)=>{const p=products.find(x=>x.id===sel.value);if(!p)return;if(resetPrice)price.value=String(p.selling_price_per_base_unit);if(priceLabel)priceLabel.firstChild!.textContent=p.unit_type==="weight"?"Selling price / "+((p.weight_price_unit||"kg")==="kg"?"kg":"gram"):"Selling price";price.readOnly=profile?.role==="worker"&&settings.workers_can_modify_selling_price!==true;unit.disabled=p.unit_type==="piece";if(resetPrice)unit.value=p.unit_type==="piece"?"piece":"grams";const n=Number(qty.value)||0,base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n,total=saleTotal(p,base,Number(price.value||0));document.querySelector("#saleTotal")!.textContent="Total: "+money(total);document.querySelectorAll<HTMLElement>("#saleProducts .product-card").forEach(x=>x.classList.toggle("selected",x.dataset.product===p.id));if(mode.value==="cash"){(f.elements.namedItem("cash") as HTMLInputElement).value=total.toFixed(2)}if(mode.value==="upi"){(f.elements.namedItem("upi") as HTMLInputElement).value=total.toFixed(2)}};
 const renderMatches=(q:string)=>{const root=document.querySelector("#saleProducts")!;const query=q.trim().toLowerCase();const matches=query?products.filter(p=>p.name.toLowerCase().includes(query)):[];root.innerHTML=matches.map(p=>'<button class="product-card" data-product="'+p.id+'"><b>'+esc(p.name)+'</b><span>'+p.current_stock_base+' available</span><strong>'+money(p.selling_price_per_base_unit)+(p.unit_type==="weight"?((p.weight_price_unit||"kg")==="kg"?"/kg":"/g"):"")+'</strong></button>').join("")+(query&&!matches.length?'<div class="notice full">No matching product.</div>':"");root.querySelectorAll<HTMLElement>("[data-product]").forEach(x=>x.addEventListener("click",()=>{sel.value=x.dataset.product!;update()}))};
 document.querySelector("#saleSearchBtn")?.addEventListener("click",()=>renderMatches((document.querySelector("#saleSearch") as HTMLInputElement).value));
 document.querySelector("#saleSearch")?.addEventListener("input",e=>renderMatches((e.target as HTMLInputElement).value));
 sel.addEventListener("change",()=>update(true));qty.addEventListener("input",()=>update(false));price.addEventListener("input",()=>update(false));unit.addEventListener("change",()=>update(false));
 document.querySelector("#saleProducts")?.addEventListener("click",e=>{const b=(e.target as HTMLElement).closest<HTMLElement>("[data-product]");if(b){sel.value=b.dataset.product!;update()}});
 const saleCreditor=f.elements.namedItem("creditor") as HTMLSelectElement;
saleCreditor.addEventListener("change",async()=>{if(saleCreditor.value!=="__new__")return;const n=prompt("Creditor name");if(!n?.trim()){saleCreditor.value="";return}const mbl=prompt("Creditor mobile number");if(!mbl?.trim()){saleCreditor.value="";return}try{const c=await createCreditor(n.trim(),mbl.trim());render();notify("Creditor registered. Select it for the sale.","success")}catch(err){saleCreditor.value="";notify(errorMessage(err),"error")}});
mode.addEventListener("change",()=>{const v=mode.value,split=v==="split"||v==="credit_split",cr=v==="credit"||v==="credit_split";if(!cr) (f.elements.namedItem("creditor") as HTMLSelectElement).value="";document.querySelector("#cashBox")?.classList.toggle("hidden",!split);document.querySelector("#upiBox")?.classList.toggle("hidden",!split);document.querySelector("#creditBox")?.classList.toggle("hidden",v!=="credit_split");document.querySelector("#creditorBox")?.classList.toggle("hidden",!cr);update(false)});update();
 f.addEventListener("submit",async e=>{e.preventDefault();const p=products.find(x=>x.id===sel.value)!;const n=Number(qty.value),base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n,total=saleTotal(p,base,Number(price.value)),v=mode.value;let cash=Number((f.elements.namedItem("cash") as HTMLInputElement).value)||0,upi=Number((f.elements.namedItem("upi") as HTMLInputElement).value)||0,credit=Number((f.elements.namedItem("credit") as HTMLInputElement).value)||0;const cr=(f.elements.namedItem("creditor") as HTMLSelectElement).value||null;if(!n||base<=0||base>p.current_stock_base)return notify("Invalid quantity or insufficient stock.","error");if(v==="cash"){cash=total;upi=0;credit=0}if(v==="upi"){cash=0;upi=total;credit=0}if(v==="credit"){cash=0;upi=0;credit=total}if(v==="split"&&Math.abs(cash+upi-total)>.01)return notify("Cash + UPI must equal total.","error");if(v==="credit_split"&&(credit<=0||Math.abs(cash+upi+credit-total)>.01))return notify("Cash + UPI + Credit must equal total.","error");if((v==="credit"||v==="credit_split")&&!cr)return notify("Select a creditor.","error");try{await saveSale({product_id:p.id,quantity_base:base,quantity_display:n,sold_unit:unit.value,selling_price_per_base_unit:Number(price.value)},v,cash,upi,credit,cr);notify("Sale completed.","success");await loadData();render()}catch(err){notify(errorMessage(err),"error")}})
}

function bindCart(){
 const add=document.querySelector<HTMLFormElement>("#cartAdd");
 if(!add)return;
 const sel=add.elements.namedItem("product") as HTMLSelectElement;
 const qty=add.elements.namedItem("qty") as HTMLInputElement;
 const unit=add.elements.namedItem("unit") as HTMLSelectElement;
 const price=add.elements.namedItem("price") as HTMLInputElement;
 const search=document.querySelector<HTMLInputElement>("#cartSearch");
 const searchBtn=document.querySelector<HTMLButtonElement>("#cartSearchBtn");
 const root=document.querySelector<HTMLElement>("#cartProducts"); const priceLabel=document.querySelector("#cartSellingLabel") as HTMLElement;

 const update=(resetPrice=true)=>{
  const p=products.find(x=>x.id===sel.value);
  if(!p)return;
  if(resetPrice)price.value=String(p.selling_price_per_base_unit);if(priceLabel)priceLabel.firstChild!.textContent=p.unit_type==="weight"?"Selling price / "+((p.weight_price_unit||"kg")==="kg"?"kg":"gram"):"Selling price";
  if(resetPrice)unit.value=p.unit_type==="piece"?"piece":"grams";
  const n=Number(qty.value)||0;
  const base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n;
  const preview=document.querySelector("#cartPreview");
  if(preview)preview.textContent="Preview: "+p.name+" × "+n+" = "+money(saleTotal(p,base,Number(price.value)));
  root?.querySelectorAll<HTMLElement>("[data-cart-product]").forEach(x=>x.classList.toggle("selected",x.dataset.cartProduct===p.id));
 };

 const renderMatches=()=>{
  if(!root||!search)return;
  const query=search.value.trim().toLowerCase();
  if(!query){root.innerHTML="";return}
  const matches=products.filter(p=>p.name.toLowerCase().includes(query));
  root.innerHTML=matches.map(p=>'<button type="button" class="product-card" data-cart-product="'+p.id+'"><b>'+esc(p.name)+'</b><span>'+p.current_stock_base+' available</span><strong>'+money(p.selling_price_per_base_unit)+'</strong></button>').join("")+
   (matches.length?"":'<div class="notice full">No matching product.</div>');
  root.querySelectorAll<HTMLElement>("[data-cart-product]").forEach(card=>{
   card.addEventListener("click",e=>{
    e.preventDefault();
    sel.value=card.dataset.cartProduct!;
    update();
   });
  });
 };

 if(search){
  search.addEventListener("input",renderMatches);
  search.addEventListener("keyup",renderMatches);
  search.addEventListener("search",renderMatches);
  search.addEventListener("change",renderMatches);
 }
 searchBtn?.addEventListener("click",e=>{e.preventDefault();renderMatches()});
 search?.form?.addEventListener("submit",e=>{e.preventDefault();renderMatches()});

 sel.addEventListener("change",()=>update(true));
 qty.addEventListener("input",()=>update(false));
 unit.addEventListener("change",()=>update(false));
 price.addEventListener("input",()=>update(false));
 update(true);

 add.addEventListener("submit",e=>{
  e.preventDefault();
  const p=products.find(x=>x.id===sel.value);
  if(!p)return notify("Select a product.","error");
  const n=Number(qty.value);
  const base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n;
  if(!n||base<=0||base>p.current_stock_base)return notify("Invalid quantity or insufficient stock.","error");
  const existing=cartItems.find(x=>x.product_id===p.id);
  if(existing){
   existing.quantity_base+=base;
   existing.quantity_display+=n;
   existing.sold_unit=unit.value;
   existing.selling_price_per_base_unit=Number(price.value);
   existing.product_name_snapshot=p.name;
   existing.purchase_price_per_base_unit=p.purchase_price_per_base_unit;
   notify("Product already in cart — quantity updated.","success");
  }else{
   cartItems.push({product_id:p.id,quantity_base:base,quantity_display:n,sold_unit:unit.value,selling_price_per_base_unit:Number(price.value),product_name_snapshot:p.name,purchase_price_per_base_unit:p.purchase_price_per_base_unit});
   notify("Added to cart.","success");
  }
  render();
 });

 document.querySelectorAll<HTMLButtonElement>(".delete-cart").forEach(b=>b.addEventListener("click",()=>{
  cartItems.splice(Number(b.dataset.i),1);render();
 }));
 document.querySelectorAll<HTMLButtonElement>(".edit-cart").forEach(b=>b.addEventListener("click",()=>{
  const i=Number(b.dataset.i),x=cartItems[i],p=products.find(p=>p.id===x.product_id)!;
  const q=Number(prompt("Quantity",String(x.quantity_display)));
  if(!q||q<=0)return;
  const base=p.unit_type==="piece"?q:x.sold_unit==="kg"?q*1000:q;
  if(base>p.current_stock_base)return notify("Insufficient stock.","error");
  const oldTotal=saleTotal(p,base,Number(x.selling_price_per_base_unit));
  const editedTotal=Number(prompt("Total money for this item",oldTotal.toFixed(2)));
  if(!Number.isFinite(editedTotal)||editedTotal<0)return;
  x.quantity_display=q;x.quantity_base=base;x.selling_price_per_base_unit=base>0?(p.unit_type==="weight"&&((p.weight_price_unit||"kg")==="kg")?editedTotal*1000/base:editedTotal/base):0;render();
 }));

 const pay=document.querySelector<HTMLFormElement>("#cartPay")!;
 const mode=pay.elements.namedItem("mode") as HTMLSelectElement;
 const cash=pay.elements.namedItem("cash") as HTMLInputElement;
 const upi=pay.elements.namedItem("upi") as HTMLInputElement;
 const credit=pay.elements.namedItem("credit") as HTMLInputElement;
 let total=cartItems.reduce((a,x)=>{const p=products.find(p=>p.id===x.product_id);return a+saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0)},0);
 const toggle=()=>{
  const v=mode.value,split=v==="split"||v==="credit_split",cr=v==="credit"||v==="credit_split";
  document.querySelector("#cartCashBox")?.classList.toggle("hidden",!split);
  document.querySelector("#cartUpiBox")?.classList.toggle("hidden",!split);
  document.querySelector("#cartCreditBox")?.classList.toggle("hidden",v!=="credit_split");
  document.querySelector("#cartCreditorBox")?.classList.toggle("hidden",!cr);
  if(v==="cash"){cash.value=total.toFixed(2);upi.value="0";credit.value="0"}
  if(v==="upi"){cash.value="0";upi.value=total.toFixed(2);credit.value="0"}
  if(v==="credit"){cash.value="0";upi.value="0";credit.value=total.toFixed(2)}
 };
 const cartCreditor=pay.elements.namedItem("creditor") as HTMLSelectElement;
 cartCreditor.addEventListener("change",async()=>{
  if(cartCreditor.value!=="__new__")return;
  const n=prompt("Creditor name");if(!n?.trim()){cartCreditor.value="";return}
  const mbl=prompt("Creditor mobile number");if(!mbl?.trim()){cartCreditor.value="";return}
  try{await createCreditor(n.trim(),mbl.trim());render();notify("Creditor registered. Select it for the sale.","success")}
  catch(err){cartCreditor.value="";notify(errorMessage(err),"error")}
 });
 mode.addEventListener("change",()=>{const v=mode.value;if(v!=="credit"&&v!=="credit_split")cartCreditor.value="";toggle()});toggle();
 pay.addEventListener("submit",async e=>{
  e.preventDefault();
  if(!cartItems.length)return notify("Add items first.","error");
  // Normalize older carts that may already contain the same product more than once.
  const merged:any[]=[];
  for(const x of cartItems){
   if(!x?.product_id||!products.some(p=>p.id===x.product_id))return notify("A cart item is no longer available. Delete it and add the product again.","error");
   const existing=merged.find(y=>y.product_id===x.product_id);
   if(existing){
    existing.quantity_base+=Number(x.quantity_base)||0;
    existing.quantity_display+=Number(x.quantity_display)||0;
   }else{
    merged.push({...x});
   }
  }
  cartItems=merged;
  total=cartItems.reduce((a,x)=>{const p=products.find(p=>p.id===x.product_id);return a+saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0)},0);
  if(!cartItems.length)return notify("Add items first.","error");
  let c=Number(cash.value)||0,u=Number(upi.value)||0,cr=Number(credit.value)||0;
  if(mode.value==="cash"){c=total;u=0;cr=0}
  if(mode.value==="upi"){c=0;u=total;cr=0}
  if(mode.value==="credit"){c=0;u=0;cr=total}
  if(mode.value==="split"&&Math.abs(c+u-total)>.01)return notify("Cash + UPI must equal total.","error");
  if(mode.value==="credit_split"&&(cr<=0||Math.abs(c+u+cr-total)>.01))return notify("Cash + UPI + Credit must equal total.","error");
  const crSelect=pay.elements.namedItem("creditor") as HTMLSelectElement,crid=crSelect.value==="__new__"?null:crSelect.value||null;
  if((mode.value==="credit"||mode.value==="credit_split")&&!crid)return notify("Select a creditor.","error");
  try{
   if(demo){
    for(const x of cartItems){
     const p=products.find(p=>p.id===x.product_id)!;
     const itemTotal=saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0);
     p.current_stock_base-=x.quantity_base;
     sales.unshift({...x,id:"cart-"+Date.now()+Math.random(),sold_at:new Date().toISOString(),worker_id:profile!.id,total_sale:itemTotal,gross_profit:saleTotal(p,Number(x.quantity_base)||0,Number(x.selling_price_per_base_unit)||0)-saleTotal(p,Number(x.quantity_base)||0,Number(p.purchase_price_per_base_unit)||0),cash_amount:c*(itemTotal/total),upi_amount:u*(itemTotal/total),credit_amount:cr*(itemTotal/total),payment_mode:mode.value,voided:false,products:{name:p.name},profiles:{full_name:profile!.full_name}});
    }
    if(cr>0&&crid)ledger.unshift({id:"cart-ledger-"+Date.now(),creditor_id:crid,type:"credit_sale",amount:cr,payment_mode:mode.value,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});
   }else{
    const r=await supabase!.rpc("complete_cart_sale",{p_worker_id:profile!.id,p_items:cartItems,p_payment_mode:mode.value,p_cash_amount:c,p_upi_amount:u,p_credit_amount:cr,p_creditor_id:crid});
    if(r.error)throw r.error;
   }
   cartItems=[];notify("Cart sale completed.","success");await loadData();render();
  }catch(err){notify(errorMessage(err),"error")}
 });
}

function productForm(){
 const h=document.querySelector("#stockForm")!;
 h.innerHTML='<div class="panel"><h3>Add Product</h3><form id="productForm" class="form-grid"><label>Name<input name="name" required></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="kg">kg</option><option value="grams">grams</option></select></label><label id="productQtyLabel">Opening quantity<input name="qty" type="number" min="0" step="any" value="0" required></label><label>Low stock limit <span class="muted tiny">(grams for weight products)</span><input name="low" type="number" min="0" step="any" value="0" required></label><label id="productPurchaseLabel">Purchase price<input name="purchase" type="number" min="0" step="any" value="0"></label><label id="productSellingLabel">Selling price<input name="sale" type="number" min="0" step="any" value="0"></label><label>Payment<select name="payment"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="pre_stock">Pre-stock recording</option></select></label><label id="productCashBox" class="hidden">Cash<input name="cash" type="number" min="0" step="any" value="0"></label><label id="productUpiBox" class="hidden">UPI<input name="upi" type="number" min="0" step="any" value="0"></label><label id="productDebtorBox" class="hidden">Supplier credit/debtor<select name="debtor"><option value="">Select debtor</option>'+debtors.map(d=>'<option value="'+d.id+'">'+esc(d.name)+' — '+esc(d.mobile)+'</option>').join("")+'<option value="__new__">＋ New Debtor</option></select></label><div class="product-photo-editor full" id="newProductPhoto"><div class="product-photo-stage product-photo-empty"><span class="ui-icon product-photo-placeholder-icon" aria-hidden="true"></span></div><div class="photo-actions"><label class="smallbtn photo-pick">Add Photo<input id="newProductPhotoInput" type="file" accept="image/*" hidden></label><button id="newProductPhotoRemove" type="button" class="smallbtn danger" disabled>Remove Photo</button></div><small class="muted">Photo is compressed before upload.</small></div><label class="check full"><input type="checkbox" name="prestock"> Pre-stock recording</label><button class="primary full">Add Product</button></form></div>';
 const f=document.querySelector<HTMLFormElement>("#productForm")!,unitEl=f.elements.namedItem("unit") as HTMLSelectElement,qtyEl=f.elements.namedItem("qty") as HTMLInputElement,mode=f.elements.namedItem("payment") as HTMLSelectElement,pre=f.elements.namedItem("prestock") as HTMLInputElement,db=f.elements.namedItem("debtor") as HTMLSelectElement,cashEl=f.elements.namedItem("cash") as HTMLInputElement,upiEl=f.elements.namedItem("upi") as HTMLInputElement;
 let pendingPhoto:File|null=null;const newPhotoStage=document.querySelector("#newProductPhoto .product-photo-stage") as HTMLElement,newPhotoInput=document.querySelector("#newProductPhotoInput") as HTMLInputElement,newPhotoRemove=document.querySelector("#newProductPhotoRemove") as HTMLButtonElement;
 const renderPendingPhoto=()=>{if(!pendingPhoto){newPhotoStage.className="product-photo-stage product-photo-empty";newPhotoStage.innerHTML='<span class="ui-icon product-photo-placeholder-icon" aria-hidden="true"></span>';newPhotoRemove.disabled=true;return}const url=URL.createObjectURL(pendingPhoto);newPhotoStage.className="product-photo-stage";newPhotoStage.innerHTML='<img src="'+esc(url)+'" alt="Selected product photo">';newPhotoRemove.disabled=false;setTimeout(()=>URL.revokeObjectURL(url),0)};
 newPhotoInput.addEventListener("change",()=>{pendingPhoto=newPhotoInput.files?.[0]||null;renderPendingPhoto()});newPhotoRemove.addEventListener("click",()=>{pendingPhoto=null;newPhotoInput.value="";renderPendingPhoto()});
 const purchaseLabel=document.querySelector("#productPurchaseLabel")!,sellingLabel=document.querySelector("#productSellingLabel")!,qtyLabel=document.querySelector("#productQtyLabel")!;
 const syncUnit=()=>{
  const u=unitEl.value,isWeight=u!=="piece";
  qtyLabel.firstChild!.textContent=isWeight?"Opening quantity ("+(u==="kg"?"kg":"grams")+")":"Opening quantity";
  purchaseLabel.firstChild!.textContent=isWeight?"Purchase price / "+(u==="kg"?"kg":"gram"):"Purchase price";
  sellingLabel.firstChild!.textContent=isWeight?"Selling price / "+(u==="kg"?"kg":"gram"):"Selling price";
 };
 const syncPayment=()=>{const v=mode.value,credit=v==="credit",split=v==="split";document.querySelector("#productDebtorBox")?.classList.toggle("hidden",!credit);document.querySelector("#productCashBox")?.classList.toggle("hidden",!split);document.querySelector("#productUpiBox")?.classList.toggle("hidden",!split);if(v==="pre_stock"){pre.checked=true;pre.disabled=true;cashEl.value="0";upiEl.value="0"}else pre.disabled=false;if(!split){cashEl.value="0";upiEl.value="0"}};
 unitEl.addEventListener("change",syncUnit);mode.addEventListener("change",()=>{if(mode.value!=="credit")db.value="";syncPayment()});syncUnit();syncPayment();
 db.addEventListener("change",async()=>{if(db.value!=="__new__")return;const n=prompt("Supplier/debtor name"),mbl=prompt("Mobile number");if(!n?.trim()||!mbl?.trim()){db.value="";return}try{await createDebtor(n.trim(),mbl.trim());render();notify("Debtor registered. Select it for the purchase.","success")}catch(err){db.value="";notify(errorMessage(err),"error")}});
 f.addEventListener("submit",async e=>{
  e.preventDefault();
  const fd=new FormData(f),name=String(fd.get("name")||"").trim(),unit=String(fd.get("unit")),q=Number(fd.get("qty")),low=Number(fd.get("low")),buy=Number(fd.get("purchase")),sell=Number(fd.get("sale")),pay=String(fd.get("payment")),pre=fd.get("prestock")==="on"||pay==="pre_stock",debtor=String(fd.get("debtor")||"")||null;
  if(!name||q<0||low<0||!Number.isFinite(buy)||buy<0||!Number.isFinite(sell)||sell<0)return notify("Enter valid product details.","error");
  const unitType=unit==="piece"?"piece":"weight",weightPriceUnit=unit==="grams"?"grams":"kg",base=unitType==="weight"?(unit==="kg"?q*1000:q):q;
  if(unitType==="piece"&&!Number.isInteger(q))return notify("Piece opening quantity must be a whole number.","error");
  let cash=0,upi=0,credit=0;
  const total=unitType==="weight"?(weightPriceUnit==="grams"?base*buy:(base/1000)*buy):base*buy;
  if(pay==="cash")cash=total;else if(pay==="upi")upi=total;else if(pay==="split"){cash=Number(cashEl.value)||0;upi=Number(upiEl.value)||0;if(cash<0||upi<0||Math.abs(cash+upi-total)>.01)return notify("Cash + UPI must equal purchase total.","error")}else if(pay==="credit"){if(!debtor)return notify("Select a debtor for credit purchase.","error");credit=total}
  if(pre){cash=0;upi=0;credit=0}
  if(demo){
   const p:Product={id:"p"+Date.now(),name,unit_type:unitType,weight_price_unit:unitType==="weight"?weightPriceUnit:undefined,current_stock_base:base,purchase_price_per_base_unit:buy,selling_price_per_base_unit:sell,low_stock_threshold_base:low,is_active:true};products.push(p);
   if(!pre)purchases.unshift({id:"q"+Date.now(),product_id:p.id,product_name_snapshot:name,quantity_base:base,quantity_display:q,purchase_unit:unitType==="piece"?"piece":unit,total_cost:total,purchase_price_per_base_unit:buy,purchased_at:new Date().toISOString(),purchased_by:profile!.id,profiles:{full_name:profile!.full_name},payment_mode:pay,cash_amount:cash,upi_amount:upi,credit_amount:credit,pre_stock:false,debtor_id:debtor});
   if(credit>0&&debtor)debtorLedger.unshift({id:"dpl"+Date.now(),debtor_id:debtor,type:"credit_purchase",amount:credit,payment_mode:"credit",cash_amount:0,upi_amount:0,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});
   notify("Product added.","success");render();return
  }
  const r=await supabase!.rpc("create_product_with_price_unit",{p_name:name,p_unit_type:unitType,p_opening_stock_base:0,p_purchase_price:buy,p_selling_price:sell,p_low_stock_threshold_base:low,p_weight_price_unit:weightPriceUnit});
  if(r.error)return notify(errorMessage(r.error),"error");
  const productId=r.data as string;let createdPhotoPath:string|null=null;
  if(pendingPhoto){try{createdPhotoPath=await uploadProductPhoto(productId,pendingPhoto)}catch(err){await supabase!.rpc("delete_product",{p_product_id:productId});return notify("Product was not added because its photo could not be uploaded: "+errorMessage(err),"error")}}
  if(base>0){
   const purchase=await supabase!.rpc("add_inventory_purchase",{p_product_id:productId,p_quantity_base:base,p_quantity_display:q,p_purchase_unit:unit==="piece"?"piece":unit,p_purchase_price:buy,p_selling_price:sell,p_payment_mode:pay,p_cash_amount:cash,p_upi_amount:upi,p_credit_amount:credit,p_debtor_id:debtor,p_pre_stock:pre,p_supplier_name:"Opening stock"});
   if(purchase.error){const created=products.find(x=>x.id===productId);if(createdPhotoPath)await supabase!.storage.from(PRODUCT_PHOTO_BUCKET).remove([createdPhotoPath]);await supabase!.rpc("delete_product",{p_product_id:productId});return notify(errorMessage(purchase.error),"error")}
  }
  await loadData();render();notify("Product added.","success")
 });
}
function purchaseForm(){
 const h=document.querySelector("#stockForm")!;
 h.innerHTML='<div class="panel"><h3>Record Purchase</h3><form id="purchaseFormInner" class="form-grid"><label>Product<select name="product">'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+'</option>').join("")+'</select></label><div class="product-photo-editor full" id="purchaseProductPhoto"><div class="product-photo-stage"></div><div class="photo-actions"><label class="smallbtn photo-pick">Change Photo<input id="purchaseProductPhotoInput" type="file" accept="image/*" hidden></label><button id="purchaseProductPhotoRemove" type="button" class="smallbtn danger" disabled>Remove Photo</button></div><small class="muted">Product photo. Compressed before upload.</small></div><label id="purchaseQtyLabel">Quantity<input name="qty" type="number" min="0" step="any" required></label><label id="purchasePriceLabel">Purchase price<input name="price" type="number" min="0" step="any" required></label><label id="purchaseSellingLabel">Selling price<input name="selling" type="number" min="0" step="any" required></label><label>Payment method<select name="payment"><option value="cash">Cash</option><option value="upi">UPI</option><option value="credit">Debt / Credit</option><option value="split">Cash + UPI</option><option value="pre_stock">Pre-stock recording</option></select></label><label id="purchaseCashBox" class="hidden">Cash<input name="cash" type="number" min="0" step="any" value="0"></label><label id="purchaseUpiBox" class="hidden">UPI<input name="upi" type="number" min="0" step="any" value="0"></label><label id="purchaseDebtorBox" class="hidden">Supplier credit/debtor<select name="debtor"><option value="">Select debtor</option>'+debtors.map(d=>'<option value="'+d.id+'">'+esc(d.name)+' — '+esc(d.mobile)+'</option>').join("")+'<option value="__new__">＋ New Debtor</option></select></label><label>Supplier / Notes<input name="supplier" placeholder="Optional supplier name"></label><label class="check full"><input type="checkbox" name="prestock"> Pre-stock recording</label><div id="purchaseTotalPreview" class="full notice">Purchase total follows the selected product price unit.</div><button class="primary full">Save Purchase</button></form></div>';
 const f=document.querySelector<HTMLFormElement>("#purchaseFormInner")!,purchasePhotoStage=document.querySelector("#purchaseProductPhoto .product-photo-stage") as HTMLElement,purchasePhotoInput=document.querySelector("#purchaseProductPhotoInput") as HTMLInputElement,purchasePhotoRemove=document.querySelector("#purchaseProductPhotoRemove") as HTMLButtonElement,productEl=f.elements.namedItem("product") as HTMLSelectElement,qtyEl=f.elements.namedItem("qty") as HTMLInputElement,priceEl=f.elements.namedItem("price") as HTMLInputElement,sellingEl=f.elements.namedItem("selling") as HTMLInputElement,mode=f.elements.namedItem("payment") as HTMLSelectElement,pre=f.elements.namedItem("prestock") as HTMLInputElement,db=f.elements.namedItem("debtor") as HTMLSelectElement,cashEl=f.elements.namedItem("cash") as HTMLInputElement,upiEl=f.elements.namedItem("upi") as HTMLInputElement;
 const qtyLabel=document.querySelector("#purchaseQtyLabel")!,priceLabel=document.querySelector("#purchasePriceLabel")!,sellingLabel=document.querySelector("#purchaseSellingLabel")!,preview=document.querySelector("#purchaseTotalPreview")!;
 const syncProduct=(resetPrices=true)=>{
  const p=products.find(x=>x.id===productEl.value);if(!p)return;
  purchasePhotoStage.innerHTML=productPhotoMarkup(p);purchasePhotoRemove.disabled=!p.photo_path;
  const isWeight=p.unit_type==="weight",pu=p.weight_price_unit||"kg";
  qtyLabel.firstChild!.textContent=isWeight?"Quantity ("+(pu==="kg"?"kg":"grams")+")":"Quantity";
  priceLabel.firstChild!.textContent=isWeight?"Purchase price / "+(pu==="kg"?"kg":"gram"):"Purchase price";
  sellingLabel.firstChild!.textContent=isWeight?"Selling price / "+(pu==="kg"?"kg":"gram"):"Selling price";
  if(resetPrices){priceEl.value=String(p.purchase_price_per_base_unit??0);sellingEl.value=String(p.selling_price_per_base_unit??0)}
  const q=Number(qtyEl.value)||0,base=isWeight?(pu==="kg"?q*1000:q):q;
  preview.textContent="Purchase total: "+money(saleTotal(p,base,Number(priceEl.value)||0));
 };
 const sync=()=>{const v=mode.value,credit=v==="credit",split=v==="split";document.querySelector("#purchaseDebtorBox")?.classList.toggle("hidden",!credit);document.querySelector("#purchaseCashBox")?.classList.toggle("hidden",!split);document.querySelector("#purchaseUpiBox")?.classList.toggle("hidden",!split);if(v==="pre_stock"){pre.checked=true;pre.disabled=true;cashEl.value="0";upiEl.value="0"}else pre.disabled=false;if(!split){cashEl.value="0";upiEl.value="0"}};
 purchasePhotoInput.addEventListener("change",async()=>{const file=purchasePhotoInput.files?.[0];if(!file)return;try{await uploadProductPhoto(productEl.value,file);syncProduct(false);notify("Product photo updated.","success")}catch(err){notify(errorMessage(err),"error")}finally{purchasePhotoInput.value=""}});
 purchasePhotoRemove.addEventListener("click",async()=>{const p=products.find(x=>x.id===productEl.value);if(!p?.photo_path)return;if(!window.confirm("Remove this product photo?"))return;try{await removeProductPhoto(p.id);syncProduct(false);notify("Product photo removed.","success")}catch(err){notify(errorMessage(err),"error")}});
 productEl.addEventListener("change",()=>syncProduct(true));qtyEl.addEventListener("input",()=>syncProduct(false));priceEl.addEventListener("input",()=>syncProduct(false));sellingEl.addEventListener("input",()=>syncProduct(false));syncProduct(true);
 mode.addEventListener("change",()=>{if(mode.value!=="credit")db.value="";sync()});sync();
 db.addEventListener("change",async()=>{if(db.value!=="__new__")return;const n=prompt("Supplier/debtor name"),mbl=prompt("Mobile number");if(!n?.trim()||!mbl?.trim()){db.value="";return}try{await createDebtor(n.trim(),mbl.trim());render();notify("Debtor registered. Select it for the purchase.","success")}catch(err){db.value="";notify(errorMessage(err),"error")}});
 f.addEventListener("submit",async e=>{
  e.preventDefault();
  const fd=new FormData(f),p=products.find(x=>x.id===String(fd.get("product"))),q=Number(fd.get("qty")),pr=Number(fd.get("price")),sell=Number(fd.get("selling")),pay=String(fd.get("payment")),prestock=fd.get("prestock")==="on"||pay==="pre_stock",debtor=String(fd.get("debtor")||"")||null;
  if(!p||q<=0||pr<0||sell<0)return notify("Invalid purchase details.","error");
  const pu=p.weight_price_unit||"kg",base=p.unit_type==="weight"?(pu==="kg"?q*1000:q):q,total=saleTotal(p,base,pr);
  let cash=0,upi=0,credit=0;
  if(pay==="cash")cash=total;else if(pay==="upi")upi=total;else if(pay==="split"){cash=Number(cashEl.value)||0;upi=Number(upiEl.value)||0;if(cash<0||upi<0||Math.abs(cash+upi-total)>.01)return notify("Cash + UPI must equal purchase total.","error")}else if(pay==="credit"){if(!debtor)return notify("Select a debtor for credit purchase.","error");credit=total}
  if(prestock){cash=0;upi=0;credit=0}
  if(demo){
   p.current_stock_base+=base;p.purchase_price_per_base_unit=pr;p.selling_price_per_base_unit=sell;
   purchases.unshift({id:"q"+Date.now(),product_id:p.id,product_name_snapshot:p.name,quantity_base:base,quantity_display:q,purchase_unit:p.unit_type==="piece"?"piece":pu,total_cost:total,purchase_price_per_base_unit:pr,purchased_at:new Date().toISOString(),purchased_by:profile!.id,profiles:{full_name:profile!.full_name},payment_mode:pay,cash_amount:cash,upi_amount:upi,credit_amount:credit,pre_stock:prestock,debtor_id:debtor,supplier_name:String(fd.get("supplier")||p.name)});
   if(credit>0&&debtor)debtorLedger.unshift({id:"dpl"+Date.now(),debtor_id:debtor,type:"credit_purchase",amount:credit,payment_mode:"credit",cash_amount:0,upi_amount:0,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});
   notify(prestock?"Pre-stock recorded.":"Purchase recorded.","success");render();return
  }
  const r=await supabase!.rpc("add_inventory_purchase",{p_product_id:p.id,p_quantity_base:base,p_quantity_display:q,p_purchase_unit:p.unit_type==="piece"?"piece":pu,p_purchase_price:pr,p_selling_price:sell,p_payment_mode:pay,p_cash_amount:cash,p_upi_amount:upi,p_credit_amount:credit,p_debtor_id:debtor,p_pre_stock:prestock,p_supplier_name:String(fd.get("supplier")||p.name)});
  if(r.error)return notify(errorMessage(r.error),"error");await loadData();render();notify(prestock?"Pre-stock recorded.":"Purchase recorded.","success")
 });
}
async function createCreditor(name:string,mobile:string){
 if(demo){const c={id:"c"+Date.now(),name,mobile};creditors.push(c);return c}
 const r=await supabase!.rpc("get_or_create_creditor",{p_name:name,p_mobile:mobile});if(r.error)throw r.error;await loadData();return r.data;
}
async function createDebtor(name:string,mobile:string){
 if(demo){const d={id:"d"+Date.now(),name,mobile};debtors.push(d);return d}
 const r=await supabase!.rpc("get_or_create_debtor",{p_name:name,p_mobile:mobile});if(r.error)throw r.error;await loadData();return r.data;
}
function debtorsView(){
 return '<section class="page debtors-page"><div class="page-head"><div><h2>Debtors</h2><p class="muted">Supplier credit purchases and payments.</p></div><button id="newDebtor" class="primary">＋ Add</button></div><div class="panel"><label>Search<input id="debtorSearch" placeholder="Name or mobile..."></label><div class="table-wrap"><table><thead><tr><th>Name</th><th>Mobile</th><th>Outstanding</th><th></th></tr></thead><tbody>'+debtors.map(d=>'<tr class="debtor-row" data-q="'+esc((d.name+" "+d.mobile).toLowerCase())+'"><td>'+esc(d.name)+'</td><td>'+esc(d.mobile)+'</td><td class="'+(dBalance(d.id)>0?"negative":"positive")+'">'+money(dBalance(d.id))+'</td><td><button class="smallbtn pay-debtor" data-id="'+d.id+'">Pay</button> <button class="smallbtn debtor-history" data-id="'+d.id+'">History</button></td></tr>').join("")+'</tbody></table></div></div><div id="debtorDetail"></div></section>';
}
function bindDebtors(){
 document.querySelector("#debtorSearch")?.addEventListener("input",e=>{const q=(e.target as HTMLInputElement).value.toLowerCase();document.querySelectorAll<HTMLElement>(".debtor-row").forEach(x=>x.style.display=(x.dataset.q||"").includes(q)?"":"none")});
 document.querySelector("#newDebtor")?.addEventListener("click",async()=>{const n=prompt("Debtor name"),mbl=prompt("Mobile");if(!n?.trim()||!mbl?.trim())return;try{await createDebtor(n.trim(),mbl.trim());await loadData();render();notify("Debtor added.","success")}catch(err){notify(errorMessage(err),"error")}});
 document.querySelectorAll<HTMLButtonElement>(".pay-debtor").forEach(b=>b.addEventListener("click",async()=>{const id=b.dataset.id!,bal=dBalance(id),amount=Number(prompt("Payment amount. Outstanding: "+money(bal)));if(!amount||amount<=0||amount>bal+0.01)return notify("Enter an amount up to the outstanding balance.","error");const mode=(prompt("Payment mode: cash, upi, split","cash")||"cash").toLowerCase();let cash=0,upi=0;if(mode==="cash")cash=amount;else if(mode==="upi")upi=amount;else if(mode==="split"){cash=Number(prompt("Cash amount","0"));if(cash<0||cash>amount)return notify("Invalid cash amount.","error");upi=amount-cash}else return notify("Invalid payment mode.","error");try{if(demo){debtorLedger.unshift({id:"dpay-"+Date.now(),debtor_id:id,type:"payment_made",amount,payment_mode:mode,cash_amount:cash,upi_amount:upi,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});let rem=amount;for(const p of purchases.filter(x=>x.debtor_id===id&&Number(x.credit_amount||0)>Number(x.credit_paid||0)).sort((a,b)=>new Date(a.purchased_at).getTime()-new Date(b.purchased_at).getTime())){const take=Math.min(rem,Number(p.credit_amount||0)-Number(p.credit_paid||0));p.credit_paid=Number(p.credit_paid||0)+take;rem-=take;if(rem<=.01)break}}else{const r=await supabase!.rpc("pay_debtor",{p_debtor_id:id,p_amount:amount,p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi});if(r.error)throw r.error}await loadData();render();notify("Debtor payment recorded.","success")}catch(err){notify(errorMessage(err),"error")}}));
 document.querySelectorAll<HTMLButtonElement>(".debtor-history").forEach(b=>b.addEventListener("click",()=>{const id=b.dataset.id!,d=debtors.find(x=>x.id===id),rows=debtorLedger.filter(x=>x.debtor_id===id);document.querySelector("#debtorDetail")!.innerHTML='<div class="panel"><div class="section-head"><h3>'+esc(d?.name)+' · '+money(dBalance(id))+' outstanding</h3><button id="closeDebtor" class="ghost">Close</button></div><div class="table-wrap"><table><thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Cash</th><th>UPI</th><th>By</th></tr></thead><tbody>'+rows.map(x=>'<tr><td>'+fmt(x.created_at)+'</td><td>'+esc(x.type)+'</td><td>'+money(x.amount)+'</td><td>'+money(x.cash_amount)+'</td><td>'+money(x.upi_amount)+'</td><td>'+esc(x.profiles?.full_name||"")+'</td></tr>').join("")+'</tbody></table></div></div>';document.querySelector("#closeDebtor")?.addEventListener("click",()=>document.querySelector("#debtorDetail")!.innerHTML="")}));
}

function creditorsView(){
 return '<section class="page creditors-page"><div class="page-head"><div><h2>Creditors</h2><p class="muted">Customer credit balances and payments.</p></div><button id="newCreditor" class="primary">＋ Add</button></div><div class="panel"><label>Search<input id="creditSearch" placeholder="Name or mobile..."></label><div class="table-wrap"><table><thead><tr><th>Name</th><th>Mobile</th><th>Outstanding</th><th></th></tr></thead><tbody>'+creditors.map(c=>'<tr class="credit-row" data-q="'+esc((c.name+" "+c.mobile).toLowerCase())+'"><td>'+esc(c.name)+'</td><td>'+esc(c.mobile)+'</td><td class="'+(qBalance(c.id)>0?"negative":"positive")+'">'+money(qBalance(c.id))+'</td><td><button class="smallbtn pay-credit" data-id="'+c.id+'">Pay</button> <button class="smallbtn credit-history" data-id="'+c.id+'">History</button></td></tr>').join("")+'</tbody></table></div></div><div id="creditDetail"></div></section>';
}
function bindCreditors(){
 document.querySelector("#creditSearch")?.addEventListener("input",e=>{const q=(e.target as HTMLInputElement).value.toLowerCase();document.querySelectorAll<HTMLElement>(".credit-row").forEach(x=>x.style.display=(x.dataset.q||"").includes(q)?"":"none")});
 document.querySelector("#newCreditor")?.addEventListener("click",async()=>{
  const n=prompt("Creditor name"),mbl=prompt("Mobile number");
  if(!n?.trim()||!mbl?.trim())return;
  try{await createCreditor(n.trim(),mbl.trim());await loadData();render();notify("Creditor registered.","success")}
  catch(err){notify(errorMessage(err),"error")}
 });
 document.querySelectorAll<HTMLButtonElement>(".pay-credit").forEach(b=>b.addEventListener("click",async()=>{
  const id=b.dataset.id!,bal=qBalance(id);
  const amount=Number(prompt("Payment received. Outstanding: "+money(bal)));
  if(!amount||amount<=0||amount>bal+0.01)return notify("Enter an amount up to the outstanding balance.","error");
  const mode=(prompt("Payment mode: cash, upi, split","cash")||"cash").toLowerCase();
  let cash=0,upi=0;
  if(mode==="cash")cash=amount;
  else if(mode==="upi")upi=amount;
  else if(mode==="split"){cash=Number(prompt("Cash amount","0"));if(cash<0||cash>amount)return notify("Invalid cash amount.","error");upi=amount-cash}
  else return notify("Invalid payment mode.","error");
  try{
   if(demo){creditors;ledger.unshift({id:"cpay-"+Date.now(),creditor_id:id,type:"payment_received",amount,payment_mode:mode,cash_amount:cash,upi_amount:upi,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}})}
   else{const r=await supabase!.rpc("receive_credit_payment",{p_creditor_id:id,p_amount:amount,p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi});if(r.error)throw r.error}
   await loadData();render();notify("Credit payment recorded.","success");
  }catch(err){notify(errorMessage(err),"error")}
 }));
 document.querySelectorAll<HTMLButtonElement>(".credit-history").forEach(b=>b.addEventListener("click",()=>{
  const id=b.dataset.id!,c=creditors.find(x=>x.id===id),rows=ledger.filter(x=>x.creditor_id===id);
  document.querySelector("#creditDetail")!.innerHTML='<div class="panel"><div class="section-head"><h3>'+esc(c?.name)+' · '+money(qBalance(id))+' outstanding</h3><button id="closeCredit" class="ghost">Close</button></div><div class="table-wrap"><table><thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Cash</th><th>UPI</th><th>By</th></tr></thead><tbody>'+rows.map(x=>'<tr><td>'+fmt(x.created_at)+'</td><td>'+esc(x.type)+'</td><td>'+money(x.amount)+'</td><td>'+money(x.cash_amount)+'</td><td>'+money(x.upi_amount)+'</td><td>'+esc(x.profiles?.full_name||"")+'</td></tr>').join("")+'</tbody></table></div></div>';
  document.querySelector("#closeCredit")?.addEventListener("click",()=>document.querySelector("#creditDetail")!.innerHTML="");
 }));
}

function historyTable(){
 const todayDate=localDate();
 const start=historyRange==="7"?Date.now()-7*864e5:historyRange==="30"?Date.now()-30*864e5:0;
 const d=historyRange==="date"?historyDate:"";
 const rows=historyType==="sales"?sales.filter(s=>!s.voided&&(!start||new Date(s.sold_at).getTime()>=start)&&(!d||localDate(new Date(s.sold_at))===d)):purchases.filter(p=>!p.pre_stock&&(!start||new Date(p.purchased_at).getTime()>=start)&&(!d||localDate(new Date(p.purchased_at))===d));
  if(historyType==="sales")return '<table><thead><tr><th>Date</th><th>Product</th><th>Qty</th><th>Sale</th><th>Profit</th><th>Cash</th><th>UPI</th><th>Credit</th></tr></thead><tbody>'+rows.map(s=>'<tr><td>'+fmt(s.sold_at)+'</td><td>'+esc((s.product_name_snapshot&&s.product_name_snapshot!=="Deleted product")?s.product_name_snapshot:(s.products?.name||"Product unavailable"))+'</td><td>'+s.quantity_display+' '+esc(s.sold_unit||"")+'</td><td>'+money(s.total_sale)+'</td><td>'+money(s.gross_profit)+'</td><td>'+money(s.cash_amount)+'</td><td>'+money(s.upi_amount)+'</td><td>'+money(saleCreditAmount(s))+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="8" class="muted">No retained sale details.</td></tr>')+'</tbody></table>';
 return '<table><thead><tr><th>Date</th><th>Product</th><th>Qty</th><th>Cost</th><th>Cash</th><th>UPI</th><th>Credit</th><th>Supplier</th><th></th></tr></thead><tbody>'+rows.map(p=>'<tr><td>'+fmt(p.purchased_at)+'</td><td>'+esc(p.product_name_snapshot)+'</td><td>'+p.quantity_display+' '+esc(p.purchase_unit||"")+'</td><td>'+money(p.total_cost)+'</td><td>'+money(p.cash_amount)+'</td><td>'+money(p.upi_amount)+'</td><td>'+money(Math.max(0,Number(p.credit_amount||0)-Number(p.credit_paid||0)))+'</td><td>'+esc(p.supplier_name||"")+'</td><td>'+(Number(p.credit_amount||0)-Number(p.credit_paid||0)>0.01?'<button class="smallbtn pay-purchase" data-id="'+p.id+'">Pay</button>':"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="9" class="muted">No retained purchase details.</td></tr>')+'</tbody></table>';
}
function legacyHistory(){
 const today=localDate();
 const matches=(d:any)=>historyRange==="today"?localDate(new Date(d))===today:historyRange==="date"?(!!historyDate&&localDate(new Date(d))===historyDate):historyRange==="7"?new Date(d).getTime()>=Date.now()-7*864e5:historyRange==="30"?new Date(d).getTime()>=Date.now()-30*864e5:true;
 const rows=historyType==="sales"
   ?sales.filter(x=>!x.voided&&matches(x.sold_at))
   :purchases.filter(x=>!x.pre_stock&&matches(x.purchased_at));
 const dates=[...new Set(rows.map(x=>localDate(new Date(historyType==="sales"?x.sold_at:x.purchased_at))))].sort().reverse();
 return '<section class="page"><div class="page-head"><div><h2>'+ (historyType==="sales"?"Sales History":"Purchase History") +'</h2><p class="muted">Today is shown by default. Search another date when needed.</p></div></div><div class="seg"><button data-history="sales" class="'+(historyType==="sales"?"active":"")+'">Sales</button><button data-history="purchases" class="'+(historyType==="purchases"?"active":"")+'">Purchases</button><button data-range="today" class="'+(historyRange==="today"?"active":"")+'">Today</button><button data-range="7" class="'+(historyRange==="7"?"active":"")+'">Last 7 Days</button><button data-range="30" class="'+(historyRange==="30"?"active":"")+'">Last 1 Month</button><button data-range="date" class="'+(historyRange==="date"?"active":"")+'">Search Date</button></div><label class="date-inline">Date<input id="historyDate" type="date" value="'+esc(historyDate)+'"></label><div class="panel"><div class="table-wrap"><table><thead><tr>'+ (historyType==="sales"?'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Profit</th>':'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Supplier</th>') +'</tr></thead><tbody>'+rows.map(x=>historyType==="sales"?'<tr><td>'+fmt(x.sold_at)+'</td><td>'+esc((x.product_name_snapshot&&x.product_name_snapshot!=="Deleted product")?x.product_name_snapshot:(x.products?.name||"Product unavailable"))+'</td><td>'+esc(x.quantity_display)+'</td><td>Cash '+money(x.cash_amount)+' · UPI '+money(x.upi_amount)+' · Credit '+money(x.credit_amount)+'</td><td>'+money(x.total_sale)+'</td><td>'+money(x.gross_profit)+'</td></tr>':'<tr><td>'+fmt(x.purchased_at)+'</td><td>'+esc(x.product_name_snapshot||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>'+esc(x.payment_mode)+'</td><td>'+money(x.total_cost)+'</td><td>'+esc(x.supplier_name||"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="6" class="muted">No records for this period.</td></tr>')+'</tbody></table></div><div class="muted tiny">Available dates: '+(dates.length?dates.join(", "):"none")+'</div></div></section>';
}
function groupSaleRows(rows:AnyRow[]):SaleVoidGroup[]{
 const grouped=new Map<string,SaleVoidGroup>();
 for(const row of rows){
  const transactionId=row.transaction_id?String(row.transaction_id):null,key=transactionId||String(row.id);
  const existing=grouped.get(key);
  if(existing)existing.rows.push(row);else grouped.set(key,{key,transactionId,rows:[row]});
 }
 return [...grouped.values()];
}
async function voidSaleGroup(group:SaleVoidGroup,button:HTMLButtonElement){
 if(voidingSaleKeys.has(group.key))return;
 const reason=window.prompt(group.transactionId?"Enter the correction reason for this cart transaction:":"Enter the correction reason for this sale:");
 if(reason===null)return;
 const trimmed=reason.trim();
 if(!trimmed)return notify("A correction reason is required.","error");
 if(!window.confirm((group.transactionId?"Void this cart transaction":"Void this sale")+"? This restores stock and reverses its financial effect."))return;
 voidingSaleKeys.add(group.key);
 const label=group.transactionId?"Void Cart":"Void Sale";
 button.disabled=true;button.textContent="Voiding…";
 try{
  const targetRows=group.transactionId?sales.filter(x=>String(x.transaction_id||"")===group.transactionId&&!x.voided):group.rows.slice(0,1);
  if(!targetRows.length)throw new Error("Sale transaction is no longer available.");
  if(demo){
   const now=new Date().toISOString();
   for(const row of targetRows){
    if(row.voided)continue;
    row.voided=true;row.void_reason=trimmed;row.voided_at=now;row.voided_by=profile?.id;
    const p=products.find(x=>x.id===row.product_id);if(p)p.current_stock_base+=Number(row.quantity_base)||0;
   }
  }else{
   if(!supabase)throw new Error("Supabase is not connected.");
   const response=group.transactionId
    ? await supabase.rpc(CART_VOID_RPC,{p_transaction_id:group.transactionId,p_reason:trimmed})
    : await supabase.rpc("void_sale",{p_sale_id:targetRows[0].id,p_reason:trimmed});
   if(response.error)throw response.error;
  }
  await loadData();
  render();
  notify(group.transactionId?"Cart transaction voided and stock restored.":"Sale voided and stock restored.","success");
 }catch(err){
  notify(errorMessage(err),"error");
  button.disabled=false;button.textContent=label;
 }finally{voidingSaleKeys.delete(group.key)}
}
function history(){
 const today=localDate();
 const matches=(d:any)=>historyRange==="today"?localDate(new Date(d))===today:historyRange==="date"?(!!historyDate&&localDate(new Date(d))===historyDate):historyRange==="7"?new Date(d).getTime()>=Date.now()-7*864e5:historyRange==="30"?new Date(d).getTime()>=Date.now()-30*864e5:true;
 const rows=historyType==="sales"?sales.filter(x=>!x.voided&&matches(x.sold_at)):purchases.filter(x=>!x.pre_stock&&matches(x.purchased_at));
 const dates=[...new Set(rows.map(x=>localDate(new Date(historyType==="sales"?x.sold_at:x.purchased_at))))].sort().reverse();
 const owner=profile?.role==="owner",groups=historyType==="sales"?groupSaleRows(rows):[];
 const voidButton=(group:SaleVoidGroup)=>'<button type="button" class="smallbtn danger void-sale" data-void-key="'+esc(group.key)+'" '+(group.transactionId?'data-transaction-id="'+esc(group.transactionId)+'"':'data-sale-id="'+esc(group.rows[0].id)+'"')+' title="'+(group.transactionId?"Void the complete cart transaction":"Void this sale")+'">'+(group.transactionId?"Void Cart":"Void Sale")+'</button>';
 const saleRows=groups.map(group=>group.rows.map((x,index)=>'<tr><td>'+fmt(x.sold_at)+'</td><td>'+esc((x.product_name_snapshot&&x.product_name_snapshot!=="Deleted product")?x.product_name_snapshot:(x.products?.name||"Product unavailable"))+'</td><td>'+esc(x.quantity_display)+'</td><td>'+(group.transactionId?'<span class="tiny">Cart · </span>':"")+'Cash '+money(x.cash_amount)+' · UPI '+money(x.upi_amount)+' · Credit '+money(saleCreditAmount(x))+'</td><td>'+money(x.total_sale)+'</td><td>'+money(x.gross_profit)+'</td>'+(owner&&index===0?'<td rowspan="'+group.rows.length+'">'+voidButton(group)+'</td>':"")+'</tr>').join("")).join("");
 const purchaseRows=rows.map(x=>'<tr><td>'+fmt(x.purchased_at)+'</td><td>'+esc(x.product_name_snapshot||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>'+esc(x.payment_mode)+'</td><td>'+money(x.total_cost)+'</td><td>'+esc(x.supplier_name||"")+'</td></tr>').join("");
 const header=historyType==="sales"?'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Profit</th>'+(owner?'<th>Actions</th>':""):'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Supplier</th>';
 const body=historyType==="sales"?saleRows:purchaseRows,colspan=historyType==="sales"&&owner?7:6;
 return '<section class="page history-page"><div class="page-head"><div><h2>'+ (historyType==="sales"?"Sales History":"Purchase History") +'</h2><p class="muted">Today is shown by default. Search another date when needed.</p></div></div><div class="seg"><button data-history="sales" class="'+(historyType==="sales"?"active":"")+'">Sales</button><button data-history="purchases" class="'+(historyType==="purchases"?"active":"")+'">Purchases</button><button data-range="today" class="'+(historyRange==="today"?"active":"")+'">Today</button><button data-range="7" class="'+(historyRange==="7"?"active":"")+'">Last 7 Days</button><button data-range="30" class="'+(historyRange==="30"?"active":"")+'">Last 1 Month</button><button data-range="date" class="'+(historyRange==="date"?"active":"")+'">Search Date</button></div><label class="date-inline">Date<input id="historyDate" type="date" value="'+esc(historyDate)+'"></label><div class="panel"><div class="table-wrap"><table><thead><tr>'+header+'</tr></thead><tbody>'+body+(rows.length?"":'<tr><td colspan="'+colspan+'" class="muted">No records for this period.</td></tr>')+'</tbody></table></div><div class="muted tiny">Available dates: '+(dates.length?dates.join(", "):"none")+'</div></div></section>';
}
function bindHistory(){
  document.querySelectorAll<HTMLElement>("[data-history]").forEach(x=>x.addEventListener("click",()=>{historyType=x.dataset.history!;historyDate="";render()}));
  document.querySelectorAll<HTMLElement>("[data-range]").forEach(x=>x.addEventListener("click",()=>{historyRange=x.dataset.range!;if(historyRange!=="date")historyDate="";render()}));
  document.querySelector("#historyDate")?.addEventListener("change",e=>{historyDate=(e.currentTarget as HTMLInputElement).value;render()});
  document.querySelectorAll<HTMLButtonElement>(".void-sale").forEach(button=>button.addEventListener("click",()=>{
   const key=String(button.dataset.voidKey||""),transactionId=button.dataset.transactionId?String(button.dataset.transactionId):null,saleId=String(button.dataset.saleId||"");
   if(!key)return;
   const rows=transactionId?sales.filter(x=>String(x.transaction_id||"")===transactionId&&!x.voided):sales.filter(x=>String(x.id||"")===saleId&&!x.voided);
   if(!rows.length)return notify("This sale is no longer available. Refresh the history and try again.","info");
   void voidSaleGroup({key,transactionId,rows},button);
  }));
  document.querySelectorAll<HTMLButtonElement>(".pay-purchase").forEach(b=>b.addEventListener("click",async()=>{
   const p=purchases.find(x=>x.id===b.dataset.id);
   if(!p)return;
   const outstanding=Number(p.credit_amount||0)-Number(p.credit_paid||0);
   const amount=Number(prompt("Purchase credit payment. Outstanding: "+money(outstanding)));
   if(!amount||amount<=0||amount>outstanding+0.01)return notify("Invalid payment amount.","error");
   if(demo){p.credit_paid=Number(p.credit_paid||0)+amount;notify("Purchase credit payment recorded.","success");render();return}
   const r=await supabase!.rpc("pay_purchase_credit",{p_purchase_id:p.id,p_amount:amount,p_payment_mode:"cash"});
   if(r.error)return notify(r.error.message,"error");
   await loadData();render();
 }));
}

function today(){
 const s=currentStats(),low=products.filter(p=>Number(p.current_stock_base)<=Number(p.low_stock_threshold_base));
 return '<section class="page today-page"><h2>Today Stats</h2><p class="muted">'+localDate()+'</p><div class="metrics">'+m("Sales",money(s.sales))+m("Profit",money(s.profit))+m("Cash",money(s.cash))+m("UPI",money(s.upi))+m("Credit",money(s.credit))+m("Transactions",String(s.tx))+m("Products",String(products.length))+m("Low Stock",String(low.length))+'</div><div class="panel"><h3>Reconciliation</h3><p>Cash + UPI + Credit: <b>'+money(s.cash+s.upi+s.credit)+'</b></p><p>Recorded sales: <b>'+money(s.sales)+'</b></p><p class="'+(Math.abs(s.cash+s.upi+s.credit-s.sales)<.01?"positive":"negative")+'">'+(Math.abs(s.cash+s.upi+s.credit-s.sales)<.01?"Balanced":"Difference: "+money(s.cash+s.upi+s.credit-s.sales))+'</p></div></section>';
}

function reports(){
 const recent=daily.filter(x=>x.business_date).slice(0,7);
 const selected=reportDate?daily.find(x=>x.business_date===reportDate):null;
 const total=lifetime||{};
 const latest=[...daily,...(lifetime?[lifetime]:[])].map((x:any)=>x.updated_at).filter(Boolean).sort().pop();
 const row=(d:any)=>'<tr><td>'+d.business_date+'</td><td>'+String(d.total_transactions||0)+'</td><td>'+money(d.total_revenue)+'</td><td>'+money(d.cash_sales)+'</td><td>'+money(d.upi_sales)+'</td><td>'+money(d.credit_sales)+'</td><td>'+money(d.total_profit)+'</td><td>'+money(d.cash_profit)+'</td><td>'+money(d.upi_profit)+'</td><td>'+money(d.credit_profit)+'</td><td>'+money(d.purchase_cash)+'</td><td>'+money(d.purchase_upi)+'</td><td>'+money(d.purchase_credit)+'</td><td>'+money(d.sales_returns)+'</td><td>'+money(d.purchase_returns)+'</td><td>'+money(d.debtor_payment_total)+'</td><td>'+money(d.debtor_payment_cash)+'</td><td>'+money(d.debtor_payment_upi)+'</td></tr>';
 const rows=selected?[selected]:recent;
 return '<section class="page reports-page"><h2>Reports</h2><div class="metrics">'+m("Lifetime Sales",money(total.lifetime_sales))+m("Lifetime Purchases",money(total.lifetime_purchases))+m("Lifetime Profit",money(total.lifetime_profit))+'</div><div class="panel"><div class="section-head"><h3>Date-wise Financials</h3><label class="date-inline">Search date<input id="reportDate" type="date" value="'+esc(reportDate)+'"></label></div><p class="muted">Latest 7 days are shown by default. Updates refresh automatically. '+(latest?'Last update: '+fmt(latest):'')+'</p><div class="table-wrap swipeable reports-scroll"><table><thead><tr><th>Date</th><th>Txn</th><th>Sales</th><th>Cash</th><th>UPI</th><th>Credit</th><th>Profit</th><th>Cash Profit</th><th>UPI Profit</th><th>Credit Profit</th><th>Cash Purchase</th><th>UPI Purchase</th><th>Debt Purchase</th><th>Sales Return</th><th>Purchase Return</th><th>Debtor Paid</th><th>Paid Cash</th><th>Paid UPI</th></tr></thead><tbody>'+rows.map(row).join("")+(rows.length?"":'<tr><td colspan="18" class="muted">No financial aggregate for this date.</td></tr>')+'</tbody></table></div></div></section>';
}

function workers(){
 const rows=workersRows.filter(x=>x.role==="worker");
 return '<section class="page workers-page"><h2>Workers</h2><div class="panel"><div class="section-head"><p class="muted">Owner-only worker list and approval status.</p><span class="badge">'+rows.length+' worker(s)</span></div><div class="table-wrap"><table><thead><tr><th>Name</th><th>Email</th><th>Status</th><th>Shop</th></tr></thead><tbody>'+rows.map(w=>'<tr><td>'+esc(w.full_name)+'</td><td>'+esc(w.email)+'</td><td>'+(w.is_active?'<span class="badge ok">Approved</span>':'<span class="badge warn">Pending</span>')+'</td><td>'+esc(w.shop_id||"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="4" class="muted">No workers found.</td></tr>')+'</tbody></table></div></div></section>';
}

function audit(){
 const d=auditDate||localDate();
 const rows=auditRows.filter(a=>localDate(new Date(a.created_at))===d);
 return '<section class="page audit-page"><div class="page-head"><div><h2>Audit</h2><p class="muted">Owner only · retained audit detail is available for 30 days.</p></div><div class="action-row"><label class="date-inline">Date<input id="auditDate" type="date" value="'+esc(auditDate||localDate())+'"></label><button id="deleteAuditDate" class="ghost">Delete This Date</button></div></div><div class="panel"><div class="table-wrap"><table><thead><tr><th>Date</th><th>Actor</th><th>Action</th><th>Entity</th></tr></thead><tbody>'+rows.map(a=>'<tr><td>'+fmt(a.created_at)+'</td><td>'+esc(a.profiles?.full_name||a.actor_id||"System")+'</td><td>'+esc(a.action)+'</td><td>'+esc(a.entity_type)+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="4" class="muted">No audit records for this date.</td></tr>')+'</tbody></table></div></div></section>';
}

function settingsView(){
 const resetParts=String(settings.dashboard_reset_time||"00:00").split(":").map(Number);
 const resetHour24=Number.isFinite(resetParts[0])?resetParts[0]:0;
 const resetMinute=Number.isFinite(resetParts[1])?resetParts[1]:0;
 const resetHour12=resetHour24===0?12:resetHour24>12?resetHour24-12:resetHour24;
 const resetPeriod=resetHour24>=12?"PM":"AM";
 const hourOptions=[1,2,3,4,5,6,7,8,9,10,11,12].map(h=>'<option value="'+h+'"'+(h===resetHour12?" selected":"")+'>'+h+'</option>').join("");
 const minuteOptions=Array.from({length:60},(_,i)=>{const v=String(i).padStart(2,"0");return '<option value="'+v+'"'+(i===resetMinute?" selected":"")+'>'+v+'</option>'}).join("");
 const periodOptions='<option value="AM"'+(resetPeriod==="AM"?" selected":"")+'>AM</option><option value="PM"'+(resetPeriod==="PM"?" selected":"")+'>PM</option>';
 return '<section class="page settings-page"><h2>Settings</h2><div class="panel"><form id="settingsForm" class="form-grid"><label>Shop name<input name="shop_name" value="'+esc(settings.shop_name)+'" required></label><label>Shop ID<input value="'+esc(settings.shop_id||profile?.shop_id||"Not configured")+'" readonly></label><label>Currency<input name="currency" value="'+esc(settings.currency||"INR")+'" required></label><label>Timezone<input name="timezone" value="'+esc(settings.timezone||"Asia/Kolkata")+'" required></label><label>Theme<select name="theme"><option value="current" '+(currentTheme()==="current"?"selected":"")+'>Current Theme</option><option value="light-pink" '+(currentTheme()==="light-pink"?"selected":"")+'>Light Pink</option><option value="pink" '+(currentTheme()==="pink"?"selected":"")+'>Pink</option></select></label><label>Dashboard reset time<div class="form-grid"><select name="resetHour">'+hourOptions+'</select><select name="resetMinute">'+minuteOptions+'</select><select name="resetPeriod">'+periodOptions+'</select></div><span class="tiny">12-hour AM/PM</span></label><label class="check"><input type="checkbox" name="allow_below_cost_sales" '+(settings.allow_below_cost_sales!==false?"checked":"")+'> Allow sales below purchase cost</label><label class="check"><input type="checkbox" name="allow_zero_price_sales" '+(settings.allow_zero_price_sales!==false?"checked":"")+'> Allow zero-price/free sales</label><label class="check"><input type="checkbox" name="workers_can_modify_selling_price" '+(settings.workers_can_modify_selling_price===true?"checked":"")+'> Workers can modify selling price</label><div class="full"><button class="primary">Save Settings</button></div></form></div><div class="panel"><h3>Supabase Project</h3><p class="muted">Owner can verify or change the connected project.</p><div class="action-row"><button id="verifyDb" class="ghost" type="button">Verify Database</button><button id="downloadSqlSettingsBtn" class="ghost" type="button">Download SQL</button><button id="downloadConnectionBtn" class="ghost" type="button">Download URL + Key</button><button id="appUpdateSettings" class="ghost" type="button">Check for App Update</button><button id="changeDb" class="ghost" type="button">Change Supabase Project</button></div></div><div class="panel"><div class="action-row"><button id="shopIdCopy" class="ghost">Copy Shop ID</button><button id="exportBtn" class="ghost">Export JSON Backup</button><button id="downloadReport" class="ghost">Download Complete TXT Report</button><button id="clearAll" class="danger">Clear All Transaction Data</button></div></div></section>';
}
function bindSettings(){
 document.querySelector("#appUpdateSettings")?.addEventListener("click",async()=>{const b=document.querySelector<HTMLButtonElement>("#appUpdateSettings");if(b){b.disabled=true;b.textContent="Checking..."}try{await checkForAppUpdate((text,type)=>notify(text,type==="danger"?"error":"info"))}finally{const x=document.querySelector<HTMLButtonElement>("#appUpdateSettings");if(x){x.disabled=false;x.textContent="Check for App Update"}}});
 document.querySelector("#settingsForm")?.addEventListener("submit",async e=>{e.preventDefault();const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),tz=String(fd.get("timezone")||"").trim();try{new Intl.DateTimeFormat("en-US",{timeZone:tz}).format()}catch{return notify("Invalid IANA timezone.","error")}const h=Number(fd.get("resetHour")||12),mi=String(fd.get("resetMinute")||"00"),period=String(fd.get("resetPeriod")||"AM"),h24=period==="AM"?(h===12?0:h):(h===12?12:h+12),next={shop_name:String(fd.get("shop_name")),currency:String(fd.get("currency")),timezone:tz,dashboard_reset_time:String(h24).padStart(2,"0")+":"+mi,allow_below_cost_sales:fd.get("allow_below_cost_sales")==="on",allow_zero_price_sales:fd.get("allow_zero_price_sales")==="on",workers_can_modify_selling_price:fd.get("workers_can_modify_selling_price")==="on",theme:normalizeTheme(fd.get("theme"))};applyTheme(next.theme);if(demo){settings={...settings,...next};notify("Settings saved.","success");render();return}const r=await supabase!.from("shop_settings").update({...next,updated_at:new Date().toISOString()}).eq("id",1);if(r.error)return notify(r.error.message,"error");settings={...settings,...next};notify("Settings saved.","success");render()});
 document.querySelector("#verifyDb")?.addEventListener("click",async()=>{
  const btn=document.querySelector<HTMLButtonElement>("#verifyDb");
  if(btn)btn.disabled=true;
  const originalText=btn?.textContent||"Verify Database";
  if(btn)btn.textContent="Verifying...";
  try{
   const r=await verifyAndUpdateDatabase();
   const version=Number(r?.database_version);
   if(!Number.isFinite(version))throw new Error("Database verification returned an invalid version.");
   if(r.updated){
    const names=Array.isArray(r.applied)?r.applied.map((x:any)=>"v"+x.version+" "+x.name).join(", "):"";
    notify("Database updated to version "+version+(names?" • "+names:"")+"." ,"success");
    try{await loadData()}catch(refreshError){notify("Database updated, but refreshing app data failed: "+errorMessage(refreshError),"error")}
   }else{
    notify("Database is up to date (version "+version+").","success");
   }
  }catch(e){notify(errorMessage(e),"error")}
  finally{
   const current=document.querySelector<HTMLButtonElement>("#verifyDb");
   if(current){current.disabled=false;current.textContent=originalText}
  }
});
 document.querySelector("#downloadSqlSettingsBtn")?.addEventListener("click",async()=>{try{const r=await fetch("/shop-management-final.sql");if(!r.ok)throw new Error("SQL file unavailable.");downloadText("shop-management-final.sql",await r.text());notify("SQL downloaded.","success")}catch(e){notify(e instanceof Error?e.message:String(e),"error")}});
 document.querySelector("#downloadConnectionBtn")?.addEventListener("click",async()=>{const c=readConn();if(!c.url||!c.key)return notify("Supabase URL and publishable key are not available on this device.","error");const content=["SHOP MANAGEMENT — SUPABASE CONNECTION","", "Supabase Project URL: "+c.url, "Supabase Publishable Key: "+c.key, "", "Keep this file private. The publishable key is intended for the client app, but the file contains your shop connection details."].join("\n");await downloadText("ShopManagement_URL_and_Key.txt",content)});
 document.querySelector("#changeDb")?.addEventListener("click",()=>login("Enter the new Supabase project details below."));
 document.querySelector("#shopIdCopy")?.addEventListener("click",async()=>{const id=String(settings.shop_id||profile?.shop_id||"");if(!id)return notify("Shop ID is not configured.","error");try{await navigator.clipboard.writeText(id);notify("Shop ID copied.","success")}catch{notify("Copy failed.","error")}});
 document.querySelector("#exportBtn")?.addEventListener("click",async()=>await downloadText("shop-data-"+localDate()+".json",JSON.stringify({exported_at:new Date().toISOString(),settings,products,sales,purchases,creditors,ledger,debtors,debtorLedger,daily,lifetime,audit:auditRows},null,2)));
 document.querySelector("#downloadReport")?.addEventListener("click",async()=>{try{
 const cutoffDate=new Date();cutoffDate.setHours(0,0,0,0);cutoffDate.setDate(cutoffDate.getDate()-89);
 let dailyRows:any[]=[],reportProducts:any[]=products;
 if(!demo&&supabase){
  const [df,pr]=await Promise.all([
   supabase.from("daily_financial_summaries").select("*").gte("business_date",localDate(cutoffDate)).lte("business_date",localDate()).order("business_date",{ascending:false}),
   supabase.from("products").select("*").eq("is_active",true).order("name")
  ]);
  if(df.error)throw df.error;
  if(pr.error)throw pr.error;
  dailyRows=df.data||[];reportProducts=pr.data||[];
 }else{
  dailyRows=daily.filter(x=>String(x.business_date)>=localDate(cutoffDate)&&String(x.business_date)<=localDate()).sort((a,b)=>String(b.business_date).localeCompare(String(a.business_date)));
 }
 const moneyTxt=(n:any)=>settings.currency+" "+new Intl.NumberFormat("en-IN",{minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(n)||0);
 const line=(c="=")=>c.repeat(78);
 const lines:string[]=[
  "SHOP MANAGEMENT — COMPLETE OWNER REPORT",
  line("="),
  "Generated: "+new Date().toLocaleString("en-IN",{dateStyle:"full",timeStyle:"medium"}),
  ""
 ];
 lines.push("1. CURRENT STOCK",line("-"));
 if(!reportProducts.length)lines.push("No products found.");
 reportProducts.forEach((p:any,i:number)=>{
  const stockUnit=p.unit_type==="piece"?"pcs":"g";
  lines.push(
   (i+1)+". "+p.name,
   "   Stock: "+p.current_stock_base+" "+stockUnit,
   "   Purchase Price: "+moneyTxt(p.purchase_price_per_base_unit),
   "   Sale Price: "+moneyTxt(p.selling_price_per_base_unit),
   "   Low Stock Limit: "+p.low_stock_threshold_base+" "+stockUnit,
   ""
  );
 });
 lines.push("2. DAILY SALES — LAST 90 DAYS",line("-"),"Date | Total Sale | Profit | Cash | UPI");
 for(let i=0;i<90;i++){
  const dt=new Date();dt.setHours(0,0,0,0);dt.setDate(dt.getDate()-i);
  const date=localDate(dt),d=dailyRows.find(x=>String(x.business_date)===date)||{};
  lines.push(date+" | "+moneyTxt(d.total_revenue)+" | "+moneyTxt(d.total_profit)+" | "+moneyTxt(d.cash_sales)+" | "+moneyTxt(d.upi_sales));
 }
 lines.push("","3. CREDITORS — OUTSTANDING",line("-"));
 const oc=creditors.map((c:any)=>({...c,balance:qBalance(c.id)})).filter((c:any)=>Number(c.balance)>0.01);
 if(!oc.length)lines.push("No outstanding creditors.");
 else oc.forEach((c:any,i:number)=>lines.push((i+1)+". "+c.name+" | Mobile: "+(c.mobile||"Not provided")+" | Amount Due: "+moneyTxt(c.balance)));
 lines.push("","4. DEBTORS — OUTSTANDING",line("-"));
 const od=debtors.map((d:any)=>({...d,balance:dBalance(d.id)})).filter((d:any)=>Number(d.balance)>0.01);
 if(!od.length)lines.push("No outstanding debtors.");
 else od.forEach((d:any,i:number)=>lines.push((i+1)+". "+d.name+" | Mobile: "+(d.mobile||"Not provided")+" | Amount Due: "+moneyTxt(d.balance)));
 lines.push("","5. 90-DAY DATE-WISE FINANCIAL REPORT",line("-"),"Date | Txn | Sales | Cash | UPI | Credit | Profit | Cash Profit | UPI Profit | Cash Purchase | UPI Purchase | Debt Purchase | Debtor Paid");
 dailyRows.sort((a,b)=>String(b.business_date).localeCompare(String(a.business_date))).forEach((d:any)=>lines.push(
  String(d.business_date)+" | "+String(d.total_transactions||0)+" | "+moneyTxt(d.total_revenue)+" | "+moneyTxt(d.cash_sales)+" | "+moneyTxt(d.upi_sales)+" | "+moneyTxt(d.credit_sales)+" | "+moneyTxt(d.total_profit)+" | "+moneyTxt(d.cash_profit)+" | "+moneyTxt(d.upi_profit)+" | "+moneyTxt(d.purchase_cash)+" | "+moneyTxt(d.purchase_upi)+" | "+moneyTxt(d.purchase_credit)+" | "+moneyTxt(d.debtor_payment_total)
 ));
 lines.push("","This report contains stock, outstanding creditor/debtor balances, and permanent 90-day date-wise financial aggregates.","It does not contain shop settings, owner/worker account information, or audit records.","");
 await downloadText("Shop_Report_All_"+localDate()+".txt",lines.join("\n"));
 notify("Complete shop report downloaded as TXT.","success");
}catch(err){notify(errorMessage(err),"error")}});document.querySelector("#clearAll")?.addEventListener("click",async()=>{if(demo)return notify("Demo data is temporary; no real database was changed.","info");if(!supabase)return notify("Supabase is not connected.","error");const confirmation=window.prompt("⚠️ DELETE ALL SHOP DATA\\n\\nThis permanently deletes sales, purchases, returns, reports, stock items/products, debtors, creditors, credit/debtor history, and transaction history from this Supabase project.\\n\\nYour owner/worker accounts, shop settings, and Supabase connection will be kept so the app remains usable.\\n\\nType DELETE exactly to continue.");if(confirmation!=="DELETE"){if(confirmation!==null)notify("Clear All cancelled. You must type DELETE exactly.","info");return}const btn=document.querySelector<HTMLButtonElement>("#clearAll");if(btn){btn.disabled=true;btn.textContent="Deleting…"}try{
 const r=await supabase.rpc("clear_all_shop_data_v2");if(r.error)throw r.error;
 let photoCleanupError:any=null;
 try{
  const photoBucket=supabase.storage.from(PRODUCT_PHOTO_BUCKET);
  const collectPhotoPaths=async(prefix:string):Promise<string[]>=>{
   const paths:string[]=[];
   const folders:string[]=[];
   let offset=0;
   while(true){
    const listed=await photoBucket.list(prefix,{limit:1000,offset,sortBy:{column:"name",order:"asc"}});
    if(listed.error)throw listed.error;
    const entries=listed.data||[];
    for(const entry of entries){
     const fullPath=prefix?prefix+"/"+entry.name:entry.name;
     if(entry.id===null)folders.push(fullPath);else paths.push(fullPath);
    }
    if(entries.length<1000)break;
    offset+=entries.length;
   }
   for(const folder of folders){
    const nested=await collectPhotoPaths(folder);
    paths.push(...nested);
   }
   return paths;
  };
  const photoPaths=await collectPhotoPaths("");
  for(let i=0;i<photoPaths.length;i+=1000){
   const removed=await photoBucket.remove(photoPaths.slice(i,i+1000));
   if(removed.error)throw removed.error;
  }
 }catch(storageErr){photoCleanupError=storageErr}
 await loadData();render();
 if(photoCleanupError)notify("All shop data was cleared, but product photo Storage cleanup failed. Please use Clear All again to retry photo cleanup.","error");
 else notify("All shop transaction, master data, and product photos were permanently deleted from Supabase.","success")
}catch(err){if(btn){btn.disabled=false;btn.textContent="Clear All Transaction Data"}notify(errorMessage(err),"error")}});
}

function returnsView(){
 const owner=profile?.role==="owner";if(!owner)return '<section class="page returns-page"><div class="panel"><h2>Returns</h2><div class="notice danger">Returns are owner-only.</div></div></section>';
 return '<section class="page"><div class="page-head"><div><h2>Returns</h2><p class="muted">Purchase returns send stock back to suppliers. Sale returns add stock back and reverse the financial effect.</p></div></div><div class="quick-grid"><button id="purchaseReturnBtn" class="primary return-purchase-btn" type="button" title="Send purchased stock back to supplier">↩ Purchase Return</button><button id="saleReturnBtn" class="ghost" type="button" title="Return customer sale">↪ Sale Return</button></div><div id="returnForm"></div><div class="panel"><h3>Recent Returns</h3><div class="table-wrap"><table><thead><tr><th>Type</th><th>Product</th><th>Qty</th><th>Amount</th><th>Payment</th><th>Date</th></tr></thead><tbody>'+returnsRows.slice(0,50).map(r=>'<tr><td>'+esc(r.return_type)+'</td><td>'+esc((r.product_name_snapshot&&r.product_name_snapshot!=="Deleted product")?r.product_name_snapshot:(r.products?.name||"Product unavailable"))+'</td><td>'+esc(r.quantity_display)+' '+esc(r.return_unit)+'</td><td>'+money(r.total_amount)+'</td><td>'+esc(r.payment_mode)+'</td><td>'+fmt(r.returned_at)+'</td></tr>').join("")+'</tbody></table></div></div></section>';
}
function bindReturns(){document.querySelector("#purchaseReturnBtn")?.addEventListener("click",()=>returnForm("purchase"));document.querySelector("#saleReturnBtn")?.addEventListener("click",()=>returnForm("sale"))}
function returnForm(type:"purchase"|"sale"){
 const sale=type==="sale",h=document.querySelector("#returnForm")!;
 h.innerHTML='<div class="panel"><h3>'+(sale?"Sale Return":"Purchase Return")+'</h3><form id="returnFormInner" class="form-grid"><label>Product<select name="product">'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+'</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min="0" step="any" required></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label><label id="returnPriceLabel">Return price<input name="price" type="number" min="0" step="any" required></label><label>Refund / balance<select name="mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="credit_adjustment">Credit / balance adjustment</option></select></label><label id="returnAccountBox" class="hidden">Account<select name="account"><option value="">Select account</option></select></label><label>Original '+(sale?"sale":"purchase")+' ID (optional)<input name="source" placeholder="Paste original ID if available"></label><div id="returnPreview" class="full notice">Enter quantity and price.</div><button class="primary full">Confirm Return</button></form></div>';
 const f=document.querySelector<HTMLFormElement>("#returnFormInner")!,priceLabel=document.querySelector("#returnPriceLabel") as HTMLElement,accountBox=document.querySelector("#returnAccountBox") as HTMLElement,account=f.elements.namedItem("account") as HTMLSelectElement,modeEl=f.elements.namedItem("mode") as HTMLSelectElement,preview=document.querySelector("#returnPreview") as HTMLElement;
 const syncPriceLabel=()=>{const p=products.find(x=>x.id===String((f.elements.namedItem("product") as HTMLSelectElement).value));if(priceLabel)priceLabel.firstChild!.textContent=p?.unit_type==="weight"?"Return price / "+((p.weight_price_unit||"kg")==="kg"?"kg":"gram"):"Return price"}; const syncAccount=()=>{accountBox.classList.toggle("hidden",modeEl.value!=="credit_adjustment");account.innerHTML='<option value="">Select account</option>'+(sale?creditors:debtors).map(c=>'<option value="'+c.id+'">'+esc(c.name)+' — '+esc(c.mobile||"")+'</option>').join("")};modeEl.addEventListener("change",syncAccount);syncAccount();
 const calc=()=>{const fd=new FormData(f),p=products.find(x=>x.id===String(fd.get("product"))),qty=Number(fd.get("qty")||0),price=Number(fd.get("price")||0),unit=String(fd.get("unit")),base=p?.unit_type==="weight"?(unit==="kg"?qty*1000:qty):qty,total=p?saleTotal(p,base,price):0;if(p)preview.textContent="Return amount: "+money(total)+" • Stock will "+(sale?"increase":"decrease")+" by "+base+(p.unit_type==="weight"?" g":" pcs")};f.addEventListener("input",calc); document.querySelector<HTMLSelectElement>('#returnFormInner select[name="product"]')?.addEventListener("change",()=>{syncPriceLabel();calc()}); syncPriceLabel();
 f.addEventListener("submit",async e=>{e.preventDefault();const fd=new FormData(f),p=products.find(x=>x.id===String(fd.get("product"))),qty=Number(fd.get("qty")),price=Number(fd.get("price")),unit=String(fd.get("unit")),mode=String(fd.get("mode")),source=String(fd.get("source")||"").trim()||null,accountId=String(fd.get("account")||"")||null;if(!p||qty<=0||price<0)return notify("Enter valid return details.","error");if(p.unit_type==="piece"&&(unit!=="piece"||qty%1!==0))return notify("Piece quantity must be a whole number.","error");if(p.unit_type==="weight"&&!["grams","kg"].includes(unit))return notify("Choose grams or kg.","error");if(mode==="credit_adjustment"&&!accountId)return notify("Select the account for a balance adjustment.","error");const base=p.unit_type==="weight"?(unit==="kg"?qty*1000:qty):qty;if(!demo){const rpc=sale?"record_sale_return":"record_purchase_return",r=await supabase!.rpc(rpc,{p_product_id:p.id,p_quantity_base:base,p_quantity_display:qty,p_return_unit:unit,p_return_price_per_base_unit:price,p_payment_mode:mode,p_source_id:source,p_account_id:accountId});if(r.error)return notify(r.error.message,"error");await loadData()}else{if(!sale&&p.current_stock_base<base)return notify("Insufficient stock for purchase return.","error");p.current_stock_base+=sale?base:-base;returnsRows.unshift({id:"demo-"+Date.now(),return_type:type,product_id:p.id,product_name_snapshot:p.name,quantity_base:base,quantity_display:qty,return_unit:unit,total_amount:saleTotal(p,base,price),payment_mode:mode,returned_at:new Date().toISOString(),products:{name:p.name}})}render();notify("Return recorded.","success")});calc();
}
let quantityStepperObserver:MutationObserver|null=null;
let quantityStepperEventsBound=false;

function changeQuantityByOne(input:HTMLInputElement,direction:-1|1){
 // Universal stepper contract:
 //  • every click is exactly +1 or -1
 //  • the current value is always the starting value
 //  • HTML step is never used for the calculation
 //  • a form reset must not put the field back to its old value
 //  • zero is the lower bound unless the field explicitly has another min
 if(input.readOnly||input.disabled)return;
 const currentText=input.value.trim();
 const parsed=Number(currentText);
 const current=Number.isFinite(parsed)?parsed:0;
 const minAttr=input.getAttribute("min");
 const maxAttr=input.getAttribute("max");
 const minParsed=minAttr===null||minAttr.trim()===""?0:Number(minAttr);
 const maxParsed=maxAttr===null||maxAttr.trim()===""?Infinity:Number(maxAttr);
 const min=Number.isFinite(minParsed)?minParsed:0;
 const max=Number.isFinite(maxParsed)?maxParsed:Infinity;
 let next=current+direction;
 if(next<min)next=min;
 if(next>max)next=max;
 const decimals=(currentText.split(".")[1]||"").length;
 const nextText=decimals?next.toFixed(decimals):String(next);

 // Set both the live value and the default value. This makes the operation
 // resistant to any form.reset()/implicit reset that may happen in another
 // listener during the same click.
 input.value=nextText;
 input.defaultValue=nextText;

 // Notify the field's existing calculation logic, but never use change/reset.
 input.dispatchEvent(new Event("input",{bubbles:true}));

 // If another synchronous listener reset the same field, immediately restore
 // the exact stepped result. A microtask also catches reset-after-listener code.
 if(input.isConnected&&input.value!==nextText){
  input.value=nextText;
  input.defaultValue=nextText;
 }
 queueMicrotask(()=>{
  if(input.isConnected&&input.value!==nextText){
   input.value=nextText;
   input.defaultValue=nextText;
  }
 });
}

function bindQuantitySteppers(){
 const inputs=Array.from(document.querySelectorAll<HTMLInputElement>('input[type="number"]'));
 inputs.forEach(input=>{
  if(input.closest(".qty-stepper")||input.dataset.qtyStepperBound==="true")return;
  const parent=input.parentElement;
  if(!parent)return;
  const wrap=document.createElement("div");
  wrap.className="qty-stepper";
  input.dataset.qtyStepperBound="true";
  parent.insertBefore(wrap,input);
  wrap.appendChild(input);

  const make=(direction:-1|1)=>{
   const b=document.createElement("button");
   b.type="button";
   b.className=direction<0?"qty-stepper-btn qty-minus":"qty-stepper-btn qty-plus";
   b.setAttribute("aria-label",direction<0?"Decrease by 1":"Increase by 1");
   b.dataset.qtyStepperFor=input.name||input.id||"number";
   b.dataset.qtyStepperDirection=String(direction);
   b.tabIndex=-1;
   b.innerHTML='<span class="ui-icon ui-icon-'+(direction<0?"minus":"plus")+'" aria-hidden="true"></span>';

   // Handle pointer presses directly so mouse/touch cannot submit or reset
   // the surrounding form. The following click is ignored so one press = one step.
   let pointerHandled=false;
   b.addEventListener("pointerdown",(event)=>{
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    if((event as PointerEvent).button!==0)return;
    pointerHandled=true;
    changeQuantityByOne(input,direction);
    window.setTimeout(()=>{pointerHandled=false},500);
   },true);
   b.addEventListener("click",(event)=>{
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    if(pointerHandled){
     pointerHandled=false;
     return;
    }
    changeQuantityByOne(input,direction);
   },true);
   return b;
  };

  const minus=make(-1),plus=make(1);
  wrap.insertBefore(minus,input);
  wrap.appendChild(plus);
 });
}

function ensureQuantityStepperObserver(){
 if(quantityStepperObserver||!app)return;
 quantityStepperObserver=new MutationObserver(mutations=>{
  const hasNewInput=mutations.some(m=>Array.from(m.addedNodes).some(node=>{
   if(!(node instanceof HTMLElement))return false;
   return node.matches('input[type="number"]')||!!node.querySelector('input[type="number"]');
  }));
  if(hasNewInput)bindQuantitySteppers();
 });
 quantityStepperObserver.observe(app,{childList:true,subtree:true});
}

function fitDashboardMetricValues(){
 const values=document.querySelectorAll<HTMLElement>(".dashboard-metrics .metric-value,.today-page .metric-value");
 values.forEach(value=>{
  value.style.fontSize="";
  const fit=()=>{
   const metric=value.parentElement as HTMLElement|null;
   if(!metric)return;
   let size=Math.min(17,Math.max(11,parseFloat(getComputedStyle(value).fontSize)||17));
   value.style.fontSize=size+"px";
   while(value.scrollWidth>value.clientWidth&&size>10){size=Math.max(10,size-0.5);value.style.fontSize=size+"px"}
  };
  fit();
  if("ResizeObserver" in window){const observer=new ResizeObserver(fit);observer.observe(value.parentElement!)}
 });
}
function bindHomeSearch(){
 const input=document.querySelector<HTMLInputElement>("#homeSearch");
 const results=document.querySelector<HTMLElement>("#homeSearchResults");
 if(!input||!results)return;
 const run=()=>{
  const q=input.value.trim();
  const menu=homeSearchItems();
  const menuMatches=q?menu.filter(x=>searchMatches(x.label+" "+x.keywords,q)):[];
  const productMatches=q?products.filter(p=>p.is_active!==false&&searchMatches([p.name,(p as any).sku,(p as any).barcode,(p as any).product_code,p.id].filter(Boolean).join(" "),q)).slice(0,8):[];
  const rows=q?[
   ...menuMatches.slice(0,8).map((x,i)=>'<button type="button" class="home-search-result" data-search-kind="menu" data-search-index="'+i+'"><span class="home-search-result-icon ui-icon ui-icon-'+(x.tab==="dashboard"?"home":x.tab==="sale"?"shopping-cart":x.tab==="stock"?"package":x.tab==="cart"?"shopping-cart":x.tab==="returns"?"rotate-ccw":x.tab==="creditors"?"wallet":x.tab==="debtors"?"wallet-cards":x.tab==="history"?"history":x.tab==="reports"?"chart-no-axes-combined":x.tab==="workers"?"users":x.tab==="audit"?"clipboard-check":"settings")+'"></span><span><b>'+esc(x.label)+'</b><small>'+esc(x.description)+'</small></span><span class="chevron">›</span></button>'),
   ...productMatches.map((p,i)=>'<button type="button" class="home-search-result" data-search-kind="product" data-product-index="'+i+'"><span class="home-search-result-icon ui-icon ui-icon-package"></span><span><b>'+esc(p.name)+'</b><small>Product shortcut · Open Stock</small></span><span class="chevron">›</span></button>')
  ]:[];
  results.innerHTML=q?(rows.length?rows.join(""):'<div class="home-search-empty">No matching menu or product found.</div>'):"";
  results.querySelectorAll<HTMLButtonElement>(".home-search-result").forEach(btn=>btn.addEventListener("click",()=>{
   if(btn.dataset.searchKind==="product"){
    const p=productMatches[Number(btn.dataset.productIndex)];
    pendingStockSearch=p?.name||"";
    activeTab="stock";lowStockOnly=false;render();
    return;
   }
   const item=menuMatches[Number(btn.dataset.searchIndex)];
   if(item)openHomeSearchItem(item);
  }));
 };
 input.addEventListener("input",run);
 document.querySelector("#homeSearchBtn")?.addEventListener("click",run);
 run();
}
function bind(){
 bindQuantitySteppers();
 ensureQuantityStepperObserver();
 if(activeTab==="dashboard")bindHomeSearch();
 if(activeTab==="dashboard")bindDashboardMetricSummaries();
 document.querySelector("#showAllStock")?.addEventListener("click",()=>{lowStockOnly=false;render()});
 document.querySelectorAll<HTMLElement>("[data-nav]").forEach(x=>x.addEventListener("click",()=>{const next=x.dataset.nav||"dashboard";if(next!=="reports")reportTableScrollLeft=0;activeTab=next;render()}));
 document.querySelector("#moreNav")?.addEventListener("click",()=>{activeTab="more";dashboardSummaryKind="";render()});
 document.querySelector("#uiBack")?.addEventListener("click",()=>{activeTab="dashboard";render()});
 document.querySelector("#addProductDashboard")?.addEventListener("click",()=>productForm());
 document.querySelector("#logout")?.addEventListener("click",async()=>{if(realtimeChannel&&supabase){await supabase.removeChannel(realtimeChannel);realtimeChannel=null}if(realtimeRefreshTimer){window.clearInterval(realtimeRefreshTimer);realtimeRefreshTimer=undefined}if(!demo)await supabase?.auth.signOut();profile=null;demo=false;demoReady=false;cartItems=[];activeTab="dashboard";login()});
 const refreshBtn=document.querySelector<HTMLButtonElement>("#refresh");
 if(refreshBtn){
  const refresh=async(e?:Event)=>{
   e?.preventDefault(); e?.stopPropagation();
   if(refreshBtn.disabled)return;
   refreshBtn.disabled=true;
   refreshBtn.textContent="↻ Refreshing…";
   try{await loadData();render();notify("Data refreshed.","success")}
   catch(err){notify(errorMessage(err),"error")}
   finally{
    const b=document.querySelector<HTMLButtonElement>("#refresh");
    if(b){b.disabled=false;b.textContent="↻ Refresh"}
   }
  };
  refreshBtn.addEventListener("click",refresh,{passive:false});
  refreshBtn.addEventListener("pointerup",refresh,{passive:false});
 }
 if(activeTab==="sale")bindSale();
 if(activeTab==="cart")bindCart();
 if(activeTab==="debtors")bindDebtors();
 if(activeTab==="creditors")bindCreditors();
 if(activeTab==="history")bindHistory(); if(activeTab==="returns")bindReturns();
 if(activeTab==="reports")document.querySelector("#reportDate")?.addEventListener("change",e=>{reportDate=(e.currentTarget as HTMLInputElement).value;render()});
 if(activeTab==="audit")document.querySelector("#auditDate")?.addEventListener("change",e=>{auditDate=(e.currentTarget as HTMLInputElement).value;render()});
 if(activeTab==="stock"){
 if(pendingStockSearch){
  const pending=pendingStockSearch;
  pendingStockSearch="";
  const input=document.querySelector<HTMLInputElement>("#stockSearch");
  if(input)input.value=pending;
 }
 document.querySelector("#addPurchase")?.addEventListener("click",purchaseForm);
 document.querySelector("#addProduct")?.addEventListener("click",productForm);
 const applyStockSearch=()=>{
  const input=document.querySelector<HTMLInputElement>("#stockSearch");
  const q=(input?.value||"").trim();
  const rows=Array.from(document.querySelectorAll<HTMLElement>(".stock-product-row"));
  let visible=0;
  rows.forEach(row=>{
   const match=searchMatches(row.dataset.search||"",q);
   row.classList.toggle("is-hidden",!match);
   if(match)visible++;
  });
  const status=document.querySelector<HTMLElement>("#stockSearchStatus");
  if(status)status.textContent=q?(visible+" matching product"+(visible===1?"":"s")+" shown"):"Showing all "+rows.length+" products";
 };
 document.querySelector("#stockSearch")?.addEventListener("input",applyStockSearch);
 document.querySelector("#stockSearchBtn")?.addEventListener("click",applyStockSearch);
 applyStockSearch();
 bindStockActions();
}
 if(activeTab==="settings")bindSettings();
 bindQuantitySteppers();
}
function addSwipeHints(){
 /* Horizontal areas use native touch/trackpad scrolling and the shared scrollbar styling. */
 document.querySelectorAll<HTMLElement>(".table-wrap,.seg,.bottom-nav,.reports-scroll").forEach(el=>{
  if(el.scrollWidth<=el.clientWidth+2)return;
  el.classList.add("swipe-scroll");
 });
}

function render(){
 if(!profile){login();return}
 const oldNav=document.querySelector<HTMLElement>(".bottom-nav");if(oldNav)bottomNavScrollLeft=oldNav.scrollLeft;
 if(activeTab==="reports"){const oldReport=document.querySelector<HTMLElement>(".reports-scroll");if(oldReport)reportTableScrollLeft=oldReport.scrollLeft;}
 app.innerHTML=shell(activeTab);
 const view=document.querySelector("#view")!;
 view.innerHTML=activeTab==="dashboard"?dashboard():activeTab==="more"?moreView():activeTab==="sale"?sale():activeTab==="cart"?cart():activeTab==="stock"?stock():activeTab==="returns"?returnsView():activeTab==="creditors"?creditorsView():activeTab==="debtors"?debtorsView():activeTab==="history"?history():activeTab==="today"?today():activeTab==="reports"?reports():activeTab==="workers"?workers():activeTab==="audit"?audit():settingsView();
 bind();
 fitDashboardMetricValues();
 const newNav=document.querySelector<HTMLElement>(".bottom-nav");if(newNav){newNav.scrollLeft=bottomNavScrollLeft;newNav.addEventListener("scroll",()=>{bottomNavScrollLeft=newNav.scrollLeft},{passive:true})}
 addSwipeHints();
 if(activeTab==="reports"){const newReport=document.querySelector<HTMLElement>(".reports-scroll");if(newReport){newReport.scrollLeft=reportTableScrollLeft;newReport.addEventListener("scroll",()=>{reportTableScrollLeft=newReport.scrollLeft},{passive:true})}}
}

function splitSqlForMobile(sql:string,maxChars=18000){
 const statements:string[]=[];let start=0,i=0,quote:string="",dollarTag:string|null=null,lineComment=false,blockComment=false;
 while(i<sql.length){
  const c=sql[i],n=sql[i+1];
  if(lineComment){if(c==="\n")lineComment=false;i++;continue}
  if(blockComment){if(c==="*"&&n==="/"){blockComment=false;i+=2;continue}i++;continue}
  if(dollarTag){if(sql.startsWith(dollarTag,i)){i+=dollarTag.length;dollarTag=null;continue}i++;continue}
  if(quote==="'"){if(c==="'"&&n==="'"){i+=2;continue}if(c==="'")quote="";i++;continue}
  if(quote==='"'){if(c==='"'&&n==='"'){i+=2;continue}if(c==='"')quote="";i++;continue}
  if(c==="-"&&n==="-"){lineComment=true;i+=2;continue}
  if(c==="/"&&n==="*"){blockComment=true;i+=2;continue}
  if(c==="'"){quote="'";i++;continue}
  if(c==='"'){quote='"';i++;continue}
  if(c==="$"){const m=sql.slice(i).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);if(m){dollarTag=m[0];i+=m[0].length;continue}}
  if(c===";"){statements.push(sql.slice(start,i+1));start=i+1}
  i++;
 }
 if(start<sql.length)statements.push(sql.slice(start));
 const chunks:string[]=[];let cur="";
 for(const st of statements){if(cur&&cur.length+st.length>maxChars){chunks.push(cur);cur=""}cur+=st}
 if(cur)chunks.push(cur);
 return chunks;
}

function login(msg=""){
 const saved=readConn();

 const renderConnection=async(message="")=>{
  app.innerHTML='<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><h2>Connect your database</h2><p class="muted">Enter your Supabase project details. The app connects directly to Supabase — Render is not required.</p>'+
   (message?'<div class="notice danger">'+esc(message)+'</div>':"")+
   '<form id="connectForm"><label>Supabase Project URL<input name="url" placeholder="https://xxxxx.supabase.co" value="'+esc(saved.url)+'" required></label>'+
   '<label>Publishable Key<input name="key" placeholder="sb_publishable_..." value="'+esc(saved.key)+'" required></label>'+
   '<button class="primary wide">Connect</button></form><button id="appUpdateLogin" class="ghost wide" type="button">Check for App Update</button>'+
   '<p class="tiny">Your URL and publishable key stay on this device. You will only need them again after reinstalling or using a new device.</p></div></div>';

  document.querySelector("#appUpdateLogin")?.addEventListener("click",async()=>{const b=document.querySelector<HTMLButtonElement>("#appUpdateLogin");if(b){b.disabled=true;b.textContent="Checking..."}try{await checkForAppUpdate((text,type)=>notify(text,type==="danger"?"error":"info"))}finally{const x=document.querySelector<HTMLButtonElement>("#appUpdateLogin");if(x){x.disabled=false;x.textContent="Check for App Update"}}});

 document.querySelector<HTMLFormElement>("#connectForm")?.addEventListener("submit",async e=>{
   e.preventDefault();
   const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),url=String(fd.get("url")||"").trim(),key=String(fd.get("key")||"").trim();
   if(!url||!key)return notify("Enter both the Supabase URL and publishable key.","error");
   await checkDatabase(url,key);
  });
 };

 const renderSetup=(missing:any[]=[])=>{
  const list=Array.isArray(missing)&&missing.length?'<ul class="tiny">'+missing.map(x=>'<li>'+esc(x)+'</li>').join("")+'</ul>':"";
  app.innerHTML='<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><h2>Database not set up</h2>'+
   '<p class="muted">This Supabase project is connected, but the Shop Management database has not been installed yet.</p>'+
   (list?'<div class="notice warning"><b>Missing:</b>'+list+'</div>':"")+
   '<div class="notice"><b>One-time setup</b><br>Copy the database SQL below, run it once in your Supabase SQL Editor, then return here and check again.</div>'+
   '<button id="copyDatabaseSql" class="primary wide">Copy Database SQL</button>'+
   '<button id="mobileSqlParts" class="ghost wide">Copy SQL in Parts (Mobile)</button>'+
   '<div id="mobileSqlPartList"></div>'+
   '<button id="downloadDatabaseSql" class="ghost wide">Download SQL</button>'+
   '<button id="checkDatabaseAgain" class="ghost wide">I\'ve Installed It — Check Again</button>'+
   '<button id="changeDatabaseFromSetup" class="ghost wide">Change Supabase Project</button>'+
   '<p class="tiny">The SQL is the same final Shop Management database schema included with this app. No Render server is required.</p></div></div>';

  document.querySelector("#copyDatabaseSql")?.addEventListener("click",async()=>{
   try{
    const rr=await fetch("/shop-management-final.sql");
    if(!rr.ok)throw new Error("SQL file unavailable.");
    const sql=await rr.text();
    try{
     await navigator.clipboard.writeText(sql);
    }catch{
     const ta=document.createElement("textarea");ta.value=sql;ta.style.position="fixed";ta.style.opacity="0";document.body.appendChild(ta);ta.focus();ta.select();
     const ok=document.execCommand("copy");ta.remove();if(!ok)throw new Error("Clipboard access was blocked.");
    }
    notify("Database SQL copied. Paste it into Supabase SQL Editor.","success");
   }catch(e){notify(e instanceof Error?e.message:String(e),"error")}
  });
  document.querySelector("#mobileSqlParts")?.addEventListener("click",async()=>{
   const host=document.querySelector("#mobileSqlPartList") as HTMLElement|null,button=document.querySelector("#mobileSqlParts") as HTMLButtonElement|null;
   if(!host)return;
   try{
    if(button){button.disabled=true;button.textContent="Preparing SQL parts..."}
    const rr=await fetch("/shop-management-final.sql");
    if(!rr.ok)throw new Error("SQL file unavailable.");
    const parts=splitSqlForMobile(await rr.text());
    host.innerHTML='<div class="notice"><b>Mobile setup:</b> '+parts.length+' safe parts. Copy, paste, and <b>Run each part in order</b>.</div>'+
      parts.map((_,i)=>'<button type="button" class="ghost wide sql-part" data-part="'+i+'">Copy SQL Part '+(i+1)+' of '+parts.length+'</button>').join("");
    host.querySelectorAll<HTMLButtonElement>(".sql-part").forEach(btn=>btn.addEventListener("click",async()=>{
      const index=Number(btn.dataset.part||-1),sql=parts[index];
      if(!sql)return;
      try{
       await navigator.clipboard.writeText(sql);
      }catch{
       const ta=document.createElement("textarea");ta.value=sql;ta.style.position="fixed";ta.style.opacity="0";document.body.appendChild(ta);ta.focus();ta.select();
       const ok=document.execCommand("copy");ta.remove();if(!ok)throw new Error("Clipboard access was blocked.");
      }
      notify("SQL Part "+(index+1)+" copied. Paste and Run it before continuing to the next part.","success");
    }));
    if(button){button.disabled=false;button.textContent="Refresh SQL Parts"}
   }catch(e){
    if(button){button.disabled=false;button.textContent="Copy SQL in Parts (Mobile)"}
    notify(e instanceof Error?e.message:String(e),"error")
   }
  });
 
  document.querySelector("#downloadDatabaseSql")?.addEventListener("click",async()=>{
   try{
    const rr=await fetch("/shop-management-final.sql");
    if(!rr.ok)throw new Error("SQL file unavailable.");
    await downloadText("shop-management-final.sql",await rr.text());
   }catch(e){notify(e instanceof Error?e.message:String(e),"error")}
  });
  document.querySelector("#checkDatabaseAgain")?.addEventListener("click",()=>checkDatabase(readConn().url,readConn().key));
  document.querySelector("#changeDatabaseFromSetup")?.addEventListener("click",()=>renderConnection());
 };

 const renderAuth=()=>{
  app.innerHTML='<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><h2>Sign in to your shop</h2><div class="notice ok">✓ Database is ready</div>'+
   '<p class="muted">Connected directly to your Supabase project.</p>'+
   '<form id="realLogin"><label>Email<input name="email" type="email" autocomplete="email" required></label><label>Password<input name="password" type="password" autocomplete="current-password" required></label><button class="primary wide">Sign In</button></form>'+
   '<div class="divider">NEW ACCOUNT</div><form id="createAccount"><label>Full name<input name="name" autocomplete="name"></label><label>Email<input name="email" type="email" autocomplete="email" required></label><label>Password<input name="password" type="password" minlength="6" autocomplete="new-password" required></label><button class="ghost wide">Create Account</button></form>'+
   '<button id="changeDatabase" class="ghost wide">Change Supabase Project</button>'+
   '<p class="tiny">Supabase URL and publishable key are saved on this device, so future logins only need your email and password.</p></div></div>';

  document.querySelector("#changeDatabase")?.addEventListener("click",()=>renderConnection());

  document.querySelector<HTMLFormElement>("#realLogin")?.addEventListener("submit",async e=>{
   e.preventDefault();
   const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),email=String(fd.get("email")||"").trim(),password=String(fd.get("password")||"");
   if(!email||!password)return notify("Enter your email and password.","error");
   const r=await supabase!.auth.signInWithPassword({email,password});
   if(r.error)return renderAuthError(r.error.message);
   await finishLogin(r.data.user.id);
  });

  document.querySelector<HTMLFormElement>("#createAccount")?.addEventListener("submit",async e=>{
   e.preventDefault();
   const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),name=String(fd.get("name")||"").trim(),email=String(fd.get("email")||"").trim(),password=String(fd.get("password")||"");
   if(!email||!password)return notify("Enter your email and password.","error");
   const r=await supabase!.auth.signUp({email,password,options:{data:{full_name:name}}});
   if(r.error)return renderAuthError(r.error.message);
   if(r.data.session&&r.data.user){await finishLogin(r.data.user.id);return}
   renderAuthError("Account created, but this Supabase project is requiring email confirmation. Disable email confirmation in Supabase Auth settings, then sign in here.");
  });
 };

 const renderAuthError=(message:string)=>{
  renderAuth();
  const card=document.querySelector(".login-card");
  if(card){const n=document.createElement("div");n.className="notice danger";n.textContent=message;card.insertBefore(n,card.querySelector("#realLogin"))}
 };

 const ensureConnection=(url:string,key:string)=>{
  if(!url||!key){renderConnection("Enter the Supabase URL and publishable key first.");return false}
  try{
   supabase=createClient(url.replace(/\/$/,""),key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}});
  }catch(e){renderConnection(e instanceof Error?e.message:"Invalid Supabase connection details.");return false}
  localStorage.setItem(URL_KEY,url.replace(/\/$/,""));
  localStorage.setItem(KEY_KEY,key);
  return true;
 };

 const checkDatabase=async(url:string,key:string)=>{
  if(!ensureConnection(url,key))return;
  app.innerHTML='<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><h2>Checking database...</h2><p class="muted">Connecting directly to Supabase and checking the Shop Management schema.</p><div class="notice">Please wait...</div></div></div>';
  try{
   const r=await supabase!.rpc("verify_shop_management",{p_expected_shop_id:""});
   if(r.error){
    const text=String(r.error.message||"");
    if(/verify_shop_management|schema cache|does not exist/i.test(text)){
     renderSetup(["Shop Management verification function"]);
     return;
    }
    renderConnection("Could not check this Supabase project: "+text);
    return;
   }
   if(!r.data?.ok){
    renderSetup(Array.isArray(r.data?.missing)?r.data.missing:[]);
    return;
   }
   const sessionResult=await supabase!.auth.getSession();
   if(sessionResult.error){
    renderAuthError(sessionResult.error.message);
    return;
   }
   if(sessionResult.data.session?.user){
    await finishLogin(sessionResult.data.session.user.id);
    return;
   }
   renderAuth();
  }catch(e){
   renderConnection("Could not connect to this Supabase project. Check the URL, publishable key, and internet connection.");
  }
 };

 const finishLogin=async(userId:string)=>{
  const p=await supabase!.from("profiles").select("*").eq("id",userId).single();
  if(p.error)return renderAuthError(p.error.message);
  profile={...p.data,role:p.data.role as Role} as Profile;
  if(!profile.is_active)return renderAuthError("This account is not active in the connected database.");
  demo=false;demoReady=false;await loadData();await setupRealtime();render();
 };

 if(msg){
  renderConnection(msg);
 }else if(saved.url&&saved.key){
  checkDatabase(saved.url,saved.key);
 }else{
  renderConnection();
 }
}

connect();login();
