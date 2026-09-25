import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { ShopDownloads } from "@shop-management/downloads";
import "./styles.css";

type Role="owner"|"worker";
type Profile={id:string;full_name:string;email:string;role:Role;is_active:boolean;shop_id?:string};
type Product={id:string;name:string;unit_type:"piece"|"weight";current_stock_base:number;purchase_price_per_base_unit:number;selling_price_per_base_unit:number;low_stock_threshold_base:number;is_active:boolean};
type AnyRow=Record<string,any>;

const URL_KEY="shop_management_supabase_url", KEY_KEY="shop_management_supabase_publishable_key";
let supabase:SupabaseClient|null=null, profile:Profile|null=null;
let settings:any={shop_name:"My Shop",currency:"INR",timezone:"Asia/Kolkata",workers_can_modify_selling_price:false,allow_below_cost_sales:true,allow_zero_price_sales:true,dashboard_reset_time:"00:00"};
let products:Product[]=[], sales:AnyRow[]=[], purchases:AnyRow[]=[], creditors:AnyRow[]=[], ledger:AnyRow[]=[], debtors:AnyRow[]=[], debtorLedger:AnyRow[]=[], daily:AnyRow[]=[], auditRows:AnyRow[]=[], workersRows:Profile[]=[], lifetime:any={};
let demo=false, demoReady=false, activeTab="dashboard", historyType="sales", historyRange="today", historyDate="", reportDate="", purchaseDate="", auditDate="";
let bottomNavScrollLeft=0;
let cartItems:AnyRow[]=[];
const app=document.querySelector<HTMLDivElement>("#app")!;

const m=(l:string,v:string)=>'<div class="metric"><span>'+l+'</span><b>'+v+'</b></div>';
const money=(n:any)=>new Intl.NumberFormat("en-IN",{style:"currency",currency:settings.currency||"INR",maximumFractionDigits:2}).format(Number(n)||0);
const esc=(s:any)=>String(s??"").replace(/[&<>\"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
const downloadText=async(fileName:string,content:string)=>{
 try{
  if(Capacitor.isNativePlatform()){await ShopDownloads.saveTextToDownloads({fileName,content});notify("Saved to Android Downloads.","success");return}
 }catch(e){notify(e instanceof Error?e.message:"Android download failed; using browser download.","error")}
 const blob=new Blob([content],{type:"text/plain;charset=utf-8"}),url=URL.createObjectURL(blob),a=document.createElement("a");
 a.href=url;a.download=fileName;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
const localDate=(d=new Date())=>new Intl.DateTimeFormat("en-CA",{timeZone:settings.timezone||"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).format(d);
const fmt=(d:any)=>d?new Date(d).toLocaleString("en-IN",{dateStyle:"short",timeStyle:"short"}):"";
const notify=(m:string,t="info")=>{const x=document.createElement("div");x.className="toast "+t;x.textContent=m;document.body.appendChild(x);setTimeout(()=>x.remove(),2800)};
const readConn=()=>({url:localStorage.getItem(URL_KEY)||"",key:localStorage.getItem(KEY_KEY)||""});
const connect=()=>{const c=readConn();if(c.url&&c.key){supabase=createClient(c.url,c.key);return true}return false};
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
  {id:"p7",name:"Moong Dal 1kg",unit_type:"weight",current_stock_base:18500,purchase_price_per_base_unit:110,selling_price_per_base_unit:135,low_stock_threshold_base:5000,is_active:true},
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
       const total=qty*(p.unit_type==="weight"?p.selling_price_per_base_unit/1000:p.selling_price_per_base_unit);
       const gp=total-(qty*(p.unit_type==="weight"?p.purchase_price_per_base_unit/1000:p.purchase_price_per_base_unit));
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
     const p=ps[i%ps.length], qty=p.unit_type==="weight"?2500+(i%5)*500:10+(i%7), cost=qty*(p.unit_type==="weight"?p.purchase_price_per_base_unit/1000:p.purchase_price_per_base_unit), mode=i%4===0?"credit":i%3===0?"split":i%2?"upi":"cash";
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
function initDemo(){if(!demoData)demoData=buildDemo();const d=demoData;products=d.products;sales=d.sales;purchases=d.purchases;creditors=d.creditors;ledger=d.ledger;debtors=d.debtors;debtorLedger=d.debtorLedger;daily=d.daily;auditRows=d.audit;workersRows=d.workers;lifetime=d.lifetime;settings={shop_name:"Demo Grocery Store",currency:"INR",timezone:"Asia/Kolkata",workers_can_modify_selling_price:true,allow_below_cost_sales:true,allow_zero_price_sales:true,dashboard_reset_time:"00:00"};profile=d.owner;demo=true;demoReady=true}
function qBalance(id:string){return ledger.filter(x=>x.creditor_id===id).reduce((a,x)=>a+(x.type==="credit_sale"||x.type==="adjustment"?Number(x.amount):x.type==="payment_received"?-Number(x.amount):0),0)}
function dBalance(id:string){return debtorLedger.filter(x=>x.debtor_id===id).reduce((a,x)=>a+(x.type==="credit_purchase"||x.type==="adjustment"?Number(x.amount):x.type==="payment_made"?-Number(x.amount):0),0)}
function currentSales(){const today=localDate();return sales.filter(s=>!s.voided&&localDate(new Date(s.sold_at))===today)}
function currentStats(){const a=currentSales();return {tx:new Set(a.map(x=>x.transaction_id||x.id)).size,sales:a.reduce((x,y)=>x+Number(y.total_sale||0),0),profit:a.reduce((x,y)=>x+Number(y.gross_profit||0),0),cash:a.reduce((x,y)=>x+Number(y.cash_amount||0),0),upi:a.reduce((x,y)=>x+Number(y.upi_amount||0),0),credit:a.reduce((x,y)=>x+Number(y.credit_amount||0),0)}}

async function loadData(){
 if(demo){if(!demoReady)initDemo();return}
 if(!supabase||!profile)return;
 const [set,p,s,q,c,l,db,dl,df,life,au,wr]=await Promise.all([
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
  supabase.from("profiles").select("*").order("full_name")
 ]);
 if(set.data)settings={...settings,...set.data};
 products=p.data||[];sales=s.data||[];purchases=q.data||[];creditors=c.data||[];ledger=l.data||[];debtors=db.data||[];debtorLedger=dl.data||[];daily=df.data||[];lifetime=life.data||{lifetime_sales:0,lifetime_purchases:0,lifetime_profit:0};auditRows=au.data||[];workersRows=(wr.data||[]).map((x:any)=>({...x,role:x.role as Role}));
}

function shell(title:string){
 const owner=profile?.role==="owner";
 const nav:[string,string][]=[["dashboard","Dashboard"],["sale","Add Sale"],["cart","Cart"],["stock","Stock"],["creditors","Creditors"],["debtors","Debtors"],["history","History"]];
 if(owner) nav.push(["today","Today Stats"],["reports","Reports"],["workers","Workers"],["audit","Audit"],["settings","Settings"]);
 return '<div class="app-shell"><header><div><b>'+esc(settings.shop_name)+'</b><span class="muted">'+esc(title)+'</span></div><button id="logout" class="ghost small">Sign out</button></header><main><div id="view"></div></main><nav class="bottom-nav">'+nav.map(([id,n])=>'<button data-nav="'+id+'" class="'+(activeTab===id?"active":"")+'">'+esc(n)+'</button>').join("")+'</nav></div>';
}

function dashboard(){
 const s=currentStats(),low=products.filter(p=>Number(p.current_stock_base)<=Number(p.low_stock_threshold_base));
 return '<section class="page"><div class="page-head"><div><h2>Dashboard</h2><p class="muted">Quick actions and stock overview.</p></div><button id="refresh" class="ghost">↻ Refresh</button></div><div class="metrics">'+m("Today Sales",money(s.sales))+m("Today Profit",money(s.profit))+m("Cash",money(s.cash))+m("UPI",money(s.upi))+m("Credit",money(s.credit))+'</div><div class="quick-grid"><button data-nav="sale">＋ Add Sale</button><button data-nav="cart">🛒 Cart</button><button data-nav="stock">Stock</button><button data-nav="creditors">Creditors</button></div><div class="panel"><div class="section-head"><h3>Stock</h3><span class="badge">'+products.length+' products</span></div><div class="table-wrap"><table><thead><tr><th>Product</th><th>Stock</th><th>Sell</th><th>Status</th></tr></thead><tbody>'+products.map(p=>'<tr><td>'+esc(p.name)+'</td><td>'+p.current_stock_base+' '+(p.unit_type==="piece"?"pcs":"g")+'</td><td>'+money(p.selling_price_per_base_unit)+'</td><td>'+(Number(p.current_stock_base)<=Number(p.low_stock_threshold_base)?'<span class="badge warn">LOW</span>':'<span class="badge ok">OK</span>')+'</td></tr>').join("")+'</tbody></table></div>'+(low.length?'<div class="notice warning">'+low.length+' product(s) are low in stock.</div>':"")+'</div></section>';
}

function sale(){
 return '<section class="page"><div class="page-head"><div><h2>Add Sale</h2><p class="muted">Search and select any product.</p></div></div><div class="panel"><div class="search-row"><input id="saleSearch" placeholder="Search product..."><button id="saleSearchBtn" class="ghost">Search</button></div><div id="saleProducts" class="product-grid"></div><form id="saleForm" class="form-grid"><label>Product<select name="product" required>'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+'</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min="0.001" step="0.001" value="1" required></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label><label>Selling price<input name="price" type="number" step=".01" min="0" required></label><label>Payment<select name="mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label><label id="cashBox" class="hidden">Cash<input name="cash" type="number" step=".01" min="0" value="0"></label><label id="upiBox" class="hidden">UPI<input name="upi" type="number" step=".01" min="0" value="0"></label><label id="creditBox" class="hidden">Credit<input name="credit" type="number" step=".01" min="0" value="0"></label><label id="creditorBox" class="hidden">Creditor<select name="creditor"><option value="">Select creditor</option>'+creditors.map(c=>'<option value="'+c.id+'">'+esc(c.name)+' — '+esc(c.mobile)+'</option>').join("")+'<option value="__new__">＋ New Creditor</option></select></label><div class="full notice" id="saleTotal">Total: ₹0.00</div><button class="primary full">Complete Sale</button></form></div></section>';
}

function cart(){
 const total=cartItems.reduce((a,x)=>a+Number(x.quantity_base)*Number(x.selling_price_per_base_unit),0);
 return '<section class="page"><div class="page-head"><h2>Cart</h2><span class="badge">'+cartItems.length+' item(s)</span></div><div class="panel"><div class="search-row"><input id="cartSearch" placeholder="Search product to add..."><button id="cartSearchBtn" class="ghost">Search</button></div><div id="cartProducts" class="product-grid compact"></div><form id="cartAdd" class="form-grid"><label>Product<select name="product">'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+' — '+p.current_stock_base+' available</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min="0.001" step=".001" value="1"></label><label>Unit<select name="unit"><option value="piece">pieces</option><option value="grams">grams</option><option value="kg">kg</option></select></label><label>Selling price<input name="price" type="number" step=".01" min="0"></label><div class="full notice" id="cartPreview">Preview: select a product</div><button class="primary full">Add to Cart</button></form><div class="notice">Cart total: <b>'+money(total)+'</b></div>'+ (cartItems.length?'<div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty</th><th>Total</th><th></th></tr></thead><tbody>'+cartItems.map((x,i)=>'<tr><td>'+esc(x.product_name_snapshot||products.find(p=>p.id===x.product_id)?.name||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>'+money(Number(x.quantity_base)*Number(x.selling_price_per_base_unit))+'</td><td><button class="smallbtn edit-cart" data-i="'+i+'">Edit</button> <button class="smallbtn delete-cart" data-i="'+i+'">Delete</button></td></tr>').join("")+'</tbody></table></div>':"")+'<div class="panel"><form id="cartPay" class="form-grid"><label>Payment<select name="mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label><label>Cash<input name="cash" type="number" step=".01" value="'+total.toFixed(2)+'"></label><label>UPI<input name="upi" type="number" step=".01" value="0"></label><label>Credit<input name="credit" type="number" step=".01" value="0"></label><label>Creditor<select name="creditor"><option value="">Select creditor</option>'+creditors.map(c=>'<option value="'+c.id+'">'+esc(c.name)+'</option>').join("")+'<option value="__new__">＋ New Creditor</option></select></label><button class="primary full" '+(cartItems.length?"":"disabled")+'>Confirm Cart Sale</button></form></div></div></section>';
}
function stock(){
 const owner=profile?.role==="owner";
 return '<section class="page"><div class="page-head"><div><h2>Stock</h2><p class="muted">Current stock and purchase actions.</p></div><div class="action-row">'+(owner?'<button id="addProduct" class="ghost">＋ Add Product</button>':"")+'<button id="addPurchase" class="primary">＋ Purchase</button></div></div><div class="panel"><div class="table-wrap"><table><thead><tr><th>Product</th><th>Current</th><th>Buy</th><th>Sell</th></tr></thead><tbody>'+products.map(p=>'<tr><td>'+esc(p.name)+'</td><td>'+p.current_stock_base+' '+(p.unit_type==="piece"?"pcs":"g")+'</td><td>'+money(p.purchase_price_per_base_unit)+'</td><td>'+money(p.selling_price_per_base_unit)+'</td></tr>').join("")+'</tbody></table></div></div><div id="stockForm"></div></section>';
}

function productForm(){
 const h=document.querySelector("#stockForm")!;h.innerHTML='<div class="panel"><h3>Add Product</h3><form id="productForm" class="form-grid"><label>Product name<input name="name" required></label><label>Unit<select name="unit"><option value="piece">Piece</option><option value="weight">Weight (grams/kg)</option></select></label><label>Quantity<input name="qty" type="number" min="0" step=".001" required></label><label>Low stock threshold<input name="low" type="number" min="0" step=".001" value="5"></label><label>Purchase price<input name="purchase" type="number" min="0" step=".01" required></label><label>Sale price<input name="sale" type="number" min="0" step=".01" required></label><div class="full notice"><b>Pre-stock recording:</b> check this if the quantity is opening/pre-recorded stock and should not become purchase history or a purchase financial entry.</div><label class="check full"><input type="checkbox" name="prestock"> Pre-stock recording</label><label class="full">Payment method<select name="payment"><option value="cash">Cash</option><option value="upi">UPI</option><option value="credit">Credit</option><option value="split">Cash + UPI</option><option value="pre_stock">Pre-stock recording</option></select></label><button class="primary full">Create Product</button></form></div>';
 const f=document.querySelector<HTMLFormElement>("#productForm")!;f.addEventListener("submit",async e=>{e.preventDefault();const fd=new FormData(f),name=String(fd.get("name")||"").trim(),unit=String(fd.get("unit")),q=Number(fd.get("qty")),low=Number(fd.get("low")),buy=Number(fd.get("purchase")),sell=Number(fd.get("sale")),pre=fd.get("prestock")==="on"||String(fd.get("payment"))==="pre_stock";if(!name||q<0)return notify("Enter valid product details.","error");if(demo){const p:Product={id:"p"+Date.now(),name,unit_type:unit==="piece"?"piece":"weight",current_stock_base:q,purchase_price_per_base_unit:buy,selling_price_per_base_unit:sell,low_stock_threshold_base:low,is_active:true};products.push(p);if(!pre)purchases.unshift({id:"q"+Date.now(),product_id:p.id,product_name_snapshot:name,quantity_base:q,quantity_display:q,purchase_unit:unit,total_cost:q*buy,purchase_price_per_base_unit:buy,purchased_at:new Date().toISOString(),purchased_by:profile!.id,profiles:{full_name:profile!.full_name},payment_mode:String(fd.get("payment")),cash_amount:String(fd.get("payment"))==="cash"?q*buy:0,upi_amount:String(fd.get("payment"))==="upi"?q*buy:0,credit_amount:String(fd.get("payment"))==="credit"?q*buy:0,pre_stock:false});notify("Product added.","success");render();return}const r=await supabase!.from("products").insert({name,unit_type:unit,current_stock_base:q,purchase_price_per_base_unit:buy,selling_price_per_base_unit:sell,low_stock_threshold_base:low,is_active:true}).select().single();if(r.error)return notify(r.error.message,"error");if(!pre){const total=q*buy;const mode=String(fd.get("payment"));const ins=await supabase!.from("inventory_purchases").insert({product_id:r.data.id,product_name_snapshot:name,quantity_base:q,quantity_display:q,purchase_unit:unit,purchase_price_per_base_unit:buy,total_cost:total,purchased_by:profile!.id,payment_mode:mode,cash_amount:mode==="cash"?total:mode==="split"?total/2:0,upi_amount:mode==="upi"?total:mode==="split"?total/2:0,credit_amount:mode==="credit"?total:0,pre_stock:false});if(ins.error)return notify(ins.error.message,"error")}await loadData();render()})}

function purchaseForm(){
 const h=document.querySelector("#stockForm")!;
 h.innerHTML='<div class="panel"><h3>Record Purchase</h3><form id="purchaseFormInner" class="form-grid"><label>Product<select name="product">'+products.map(p=>'<option value="'+p.id+'">'+esc(p.name)+'</option>').join("")+'</select></label><label>Quantity<input name="qty" type="number" min=".001" step=".001" required></label><label>Purchase price<input name="price" type="number" min="0" step=".01" required></label><label>Payment method<select name="payment"><option value="cash">Cash</option><option value="upi">UPI</option><option value="credit">Debt / Credit</option><option value="split">Cash + UPI</option><option value="pre_stock">Pre-stock recording</option></select></label><label id="purchaseDebtorBox" class="hidden">Debtor<select name="debtor"><option value="">Select debtor</option>'+debtors.map(d=>'<option value="'+d.id+'">'+esc(d.name)+' — '+esc(d.mobile)+'</option>').join("")+'<option value="__new__">＋ New Debtor</option></select></label><label>Supplier / Notes<input name="supplier" placeholder="Optional supplier name"></label><label class="check full"><input type="checkbox" name="prestock"> Pre-stock recording (excluded from purchase history/reports)</label><div class="full notice">Normal purchases increase stock and are retained for 1 year. Credit purchases are recorded against a debtor. Pre-stock records are excluded from purchase history and financial purchase totals.</div><button class="primary full">Save Purchase</button></form></div>';
 const f=document.querySelector<HTMLFormElement>("#purchaseFormInner")!;
 const mode=f.elements.namedItem("payment") as HTMLSelectElement,pre=f.elements.namedItem("prestock") as HTMLInputElement,db=f.elements.namedItem("debtor") as HTMLSelectElement;
 const sync=()=>{const isCredit=mode.value==="credit";document.querySelector("#purchaseDebtorBox")?.classList.toggle("hidden",!isCredit);if(mode.value==="pre_stock"){pre.checked=true;pre.disabled=true}else pre.disabled=false};
 mode.addEventListener("change",sync);sync();
 db.addEventListener("change",async()=>{if(db.value!=="__new__")return;const n=prompt("Debtor name");if(!n?.trim()){db.value="";return}const mbl=prompt("Debtor mobile number");if(!mbl?.trim()){db.value="";return}try{await createDebtor(n.trim(),mbl.trim());render();notify("Debtor registered. Select it for the purchase.","success")}catch(err){db.value="";notify(err instanceof Error?err.message:String(err),"error")}});
 f.addEventListener("submit",async e=>{e.preventDefault();const fd=new FormData(f),p=products.find(x=>x.id===String(fd.get("product")))!;const q=Number(fd.get("qty")),pr=Number(fd.get("price")),pay=String(fd.get("payment")),isPre=fd.get("prestock")==="on"||pay==="pre_stock",total=p.unit_type==="weight"?(q*pr/1000):q*pr;const debtorId=db.value==="__new__"?null:(db.value||null);if(!q||q<=0)return notify("Invalid quantity.","error");if(pay==="credit"&&!debtorId)return notify("Select a debtor for a credit purchase.","error");const cash=pay==="cash"?total:pay==="split"?total/2:0,upi=pay==="upi"?total:pay==="split"?total/2:0,credit=pay==="credit"?total:0;if(demo){p.current_stock_base+=q;p.purchase_price_per_base_unit=pr;const row={id:"q"+Date.now(),product_id:p.id,product_name_snapshot:p.name,quantity_base:q,quantity_display:q,purchase_unit:p.unit_type==="weight"?"grams":"piece",total_cost:total,purchase_price_per_base_unit:pr,purchased_at:new Date().toISOString(),purchased_by:profile!.id,profiles:{full_name:profile!.full_name},payment_mode:pay,cash_amount:cash,upi_amount:upi,credit_amount:credit,credit_paid:0,pre_stock:isPre,supplier_name:String(fd.get("supplier")||""),debtor_id:debtorId};if(!isPre)purchases.unshift(row);if(credit>0&&debtorId)debtorLedger.unshift({id:"dl"+Date.now(),debtor_id:debtorId,type:"credit_purchase",amount:credit,payment_mode:"credit",cash_amount:0,upi_amount:0,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});notify(isPre?"Pre-stock recorded.":"Purchase recorded.","success");render();return}const ins=await supabase!.from("inventory_purchases").insert({product_id:p.id,product_name_snapshot:p.name,quantity_base:q,quantity_display:q,purchase_unit:p.unit_type==="weight"?"grams":"piece",purchase_price_per_base_unit:pr,total_cost:total,purchased_by:profile!.id,payment_mode:pay,cash_amount:cash,upi_amount:upi,credit_amount:credit,credit_paid:0,pre_stock:isPre,supplier_name:String(fd.get("supplier")||""),debtor_id:debtorId});if(ins.error)return notify(ins.error.message,"error");const up=await supabase!.from("products").update({current_stock_base:Number(p.current_stock_base)+q,purchase_price_per_base_unit:pr}).eq("id",p.id);if(up.error)return notify(up.error.message,"error");await loadData();render()});
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
 return '<section class="page"><div class="page-head"><div><h2>Debtors</h2><p class="muted">Supplier credit purchases and payments.</p></div><button id="newDebtor" class="primary">＋ Add</button></div><div class="panel"><label>Search<input id="debtorSearch" placeholder="Name or mobile..."></label><div class="table-wrap"><table><thead><tr><th>Name</th><th>Mobile</th><th>Outstanding</th><th></th></tr></thead><tbody>'+debtors.map(d=>'<tr class="debtor-row" data-q="'+esc((d.name+" "+d.mobile).toLowerCase())+'"><td>'+esc(d.name)+'</td><td>'+esc(d.mobile)+'</td><td class="'+(dBalance(d.id)>0?"negative":"positive")+'">'+money(dBalance(d.id))+'</td><td><button class="smallbtn pay-debtor" data-id="'+d.id+'">Pay</button> <button class="smallbtn debtor-history" data-id="'+d.id+'">History</button></td></tr>').join("")+'</tbody></table></div></div><div id="debtorDetail"></div></section>';
}
function bindDebtors(){
 document.querySelector("#debtorSearch")?.addEventListener("input",e=>{const q=(e.target as HTMLInputElement).value.toLowerCase();document.querySelectorAll<HTMLElement>(".debtor-row").forEach(x=>x.style.display=(x.dataset.q||"").includes(q)?"":"none")});
 document.querySelector("#newDebtor")?.addEventListener("click",async()=>{const n=prompt("Debtor name"),mbl=prompt("Mobile");if(!n?.trim()||!mbl?.trim())return;try{await createDebtor(n.trim(),mbl.trim());await loadData();render()}catch(err){notify(err instanceof Error?err.message:String(err),"error")}});
 document.querySelectorAll<HTMLButtonElement>(".pay-debtor").forEach(b=>b.addEventListener("click",async()=>{const id=b.dataset.id!,bal=dBalance(id),amount=Number(prompt("Payment amount. Outstanding: "+money(bal)));if(!amount||amount<=0||amount>bal+0.01)return notify("Enter an amount up to the outstanding balance.","error");const mode=(prompt("Payment mode: cash, upi, split","cash")||"cash").toLowerCase();let cash=0,upi=0;if(mode==="cash")cash=amount;else if(mode==="upi")upi=amount;else if(mode==="split"){cash=Number(prompt("Cash amount","0"));if(cash<0||cash>amount)return notify("Invalid cash amount.","error");upi=amount-cash}else return notify("Invalid payment mode.","error");try{if(demo){debtorLedger.unshift({id:"dpay-"+Date.now(),debtor_id:id,type:"payment_made",amount,payment_mode:mode,cash_amount:cash,upi_amount:upi,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});let rem=amount;for(const p of purchases.filter(x=>x.debtor_id===id&&Number(x.credit_amount||0)>Number(x.credit_paid||0)).sort((a,b)=>new Date(a.purchased_at).getTime()-new Date(b.purchased_at).getTime())){const take=Math.min(rem,Number(p.credit_amount||0)-Number(p.credit_paid||0));p.credit_paid=Number(p.credit_paid||0)+take;rem-=take;if(rem<=.01)break}}else{const r=await supabase!.rpc("pay_debtor",{p_debtor_id:id,p_amount:amount,p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi});if(r.error)throw r.error}await loadData();render()}catch(err){notify(err instanceof Error?err.message:String(err),"error")}}));
 document.querySelectorAll<HTMLButtonElement>(".debtor-history").forEach(b=>b.addEventListener("click",()=>{const id=b.dataset.id!,d=debtors.find(x=>x.id===id),rows=debtorLedger.filter(x=>x.debtor_id===id);document.querySelector("#debtorDetail")!.innerHTML='<div class="panel"><div class="section-head"><h3>'+esc(d?.name)+' · '+money(dBalance(id))+' outstanding</h3><button id="closeDebtor" class="ghost">Close</button></div><div class="table-wrap"><table><thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Cash</th><th>UPI</th><th>By</th></tr></thead><tbody>'+rows.map(x=>'<tr><td>'+fmt(x.created_at)+'</td><td>'+esc(x.type)+'</td><td>'+money(x.amount)+'</td><td>'+money(x.cash_amount)+'</td><td>'+money(x.upi_amount)+'</td><td>'+esc(x.profiles?.full_name||"")+'</td></tr>').join("")+'</tbody></table></div></div>';document.querySelector("#closeDebtor")?.addEventListener("click",()=>document.querySelector("#debtorDetail")!.innerHTML="")}));
}

function creditorsView(){
 return '<section class="page"><div class="page-head"><div><h2>Creditors</h2><p class="muted">Customer credit balances and payments.</p></div><button id="newCreditor" class="primary">＋ Add</button></div><div class="panel"><label>Search<input id="creditSearch" placeholder="Name or mobile..."></label><div class="table-wrap"><table><thead><tr><th>Name</th><th>Mobile</th><th>Outstanding</th><th></th></tr></thead><tbody>'+creditors.map(c=>'<tr class="credit-row" data-q="'+esc((c.name+" "+c.mobile).toLowerCase())+'"><td>'+esc(c.name)+'</td><td>'+esc(c.mobile)+'</td><td class="'+(qBalance(c.id)>0?"negative":"positive")+'">'+money(qBalance(c.id))+'</td><td><button class="smallbtn pay-credit" data-id="'+c.id+'">Pay</button> <button class="smallbtn credit-history" data-id="'+c.id+'">History</button></td></tr>').join("")+'</tbody></table></div></div><div id="creditDetail"></div></section>';
}

function historyTable(){
 const todayDate=localDate();
 const start=historyRange==="7"?Date.now()-7*864e5:historyRange==="30"?Date.now()-30*864e5:0;
 const d=historyRange==="date"?historyDate:"";
 const rows=historyType==="sales"?sales.filter(s=>!s.voided&&(!start||new Date(s.sold_at).getTime()>=start)&&(!d||localDate(new Date(s.sold_at))===d)):purchases.filter(p=>!p.pre_stock&&(!start||new Date(p.purchased_at).getTime()>=start)&&(!d||localDate(new Date(p.purchased_at))===d));
 if(historyType==="sales")return '<table><thead><tr><th>Date</th><th>Product</th><th>Qty</th><th>Sale</th><th>Profit</th><th>Cash</th><th>UPI</th><th>Credit</th></tr></thead><tbody>'+rows.map(s=>'<tr><td>'+fmt(s.sold_at)+'</td><td>'+esc(s.products?.name||s.product_name_snapshot)+'</td><td>'+s.quantity_display+' '+esc(s.sold_unit||"")+'</td><td>'+money(s.total_sale)+'</td><td>'+money(s.gross_profit)+'</td><td>'+money(s.cash_amount)+'</td><td>'+money(s.upi_amount)+'</td><td>'+money(s.credit_amount||((s.payment_mode==="credit")?s.total_sale:0))+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="8" class="muted">No retained sale details.</td></tr>')+'</tbody></table>';
 return '<table><thead><tr><th>Date</th><th>Product</th><th>Qty</th><th>Cost</th><th>Cash</th><th>UPI</th><th>Credit</th><th>Supplier</th><th></th></tr></thead><tbody>'+rows.map(p=>'<tr><td>'+fmt(p.purchased_at)+'</td><td>'+esc(p.product_name_snapshot)+'</td><td>'+p.quantity_display+' '+esc(p.purchase_unit||"")+'</td><td>'+money(p.total_cost)+'</td><td>'+money(p.cash_amount)+'</td><td>'+money(p.upi_amount)+'</td><td>'+money(Math.max(0,Number(p.credit_amount||0)-Number(p.credit_paid||0)))+'</td><td>'+esc(p.supplier_name||"")+'</td><td>'+(Number(p.credit_amount||0)-Number(p.credit_paid||0)>0.01?'<button class="smallbtn pay-purchase" data-id="'+p.id+'">Pay</button>':"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="9" class="muted">No retained purchase details.</td></tr>')+'</tbody></table>';
}
function history(){
 const today=localDate();
 const matches=(d:any)=>historyRange==="today"?localDate(new Date(d))===today:historyRange==="date"?(!!historyDate&&localDate(new Date(d))===historyDate):historyRange==="7"?new Date(d).getTime()>=Date.now()-7*864e5:historyRange==="30"?new Date(d).getTime()>=Date.now()-30*864e5:true;
 const rows=historyType==="sales"
   ?sales.filter(x=>!x.voided&&matches(x.sold_at))
   :purchases.filter(x=>!x.pre_stock&&matches(x.purchased_at));
 const dates=[...new Set(rows.map(x=>localDate(new Date(historyType==="sales"?x.sold_at:x.purchased_at))))].sort().reverse();
 return '<section class="page"><div class="page-head"><div><h2>'+ (historyType==="sales"?"Sales History":"Purchase History") +'</h2><p class="muted">Today is shown by default. Search another date when needed.</p></div></div><div class="seg"><button data-history="sales" class="'+(historyType==="sales"?"active":"")+'">Sales</button><button data-history="purchases" class="'+(historyType==="purchases"?"active":"")+'">Purchases</button><button data-range="today" class="'+(historyRange==="today"?"active":"")+'">Today</button><button data-range="7" class="'+(historyRange==="7"?"active":"")+'">Last 7 Days</button><button data-range="30" class="'+(historyRange==="30"?"active":"")+'">Last 1 Month</button><button data-range="date" class="'+(historyRange==="date"?"active":"")+'">Search Date</button></div><label class="date-inline">Date<input id="historyDate" type="date" value="'+esc(historyDate)+'"></label><div class="panel"><div class="table-wrap"><table><thead><tr>'+ (historyType==="sales"?'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Profit</th>':'<th>Date</th><th>Product</th><th>Qty</th><th>Payment</th><th>Total</th><th>Supplier</th>') +'</tr></thead><tbody>'+rows.map(x=>historyType==="sales"?'<tr><td>'+fmt(x.sold_at)+'</td><td>'+esc(x.product_name_snapshot||x.products?.name||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>Cash '+money(x.cash_amount)+' · UPI '+money(x.upi_amount)+' · Credit '+money(x.credit_amount)+'</td><td>'+money(x.total_sale)+'</td><td>'+money(x.gross_profit)+'</td></tr>':'<tr><td>'+fmt(x.purchased_at)+'</td><td>'+esc(x.product_name_snapshot||"")+'</td><td>'+esc(x.quantity_display)+'</td><td>'+esc(x.payment_mode)+'</td><td>'+money(x.total_cost)+'</td><td>'+esc(x.supplier_name||"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="6" class="muted">No records for this period.</td></tr>')+'</tbody></table></div><div class="muted tiny">Available dates: '+(dates.length?dates.join(", "):"none")+'</div></div></section>';
}
function bindHistory(){
 document.querySelectorAll<HTMLElement>("[data-history]").forEach(x=>x.addEventListener("click",()=>{historyType=x.dataset.history!;historyDate="";render()}));
 document.querySelectorAll<HTMLElement>("[data-range]").forEach(x=>x.addEventListener("click",()=>{historyRange=x.dataset.range!;if(historyRange!=="date")historyDate="";render()}));
 document.querySelector("#historyDate")?.addEventListener("change",e=>{historyDate=(e.currentTarget as HTMLInputElement).value;render()});
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
 return '<section class="page"><h2>Today Stats</h2><p class="muted">'+localDate()+'</p><div class="metrics">'+m("Sales",money(s.sales))+m("Profit",money(s.profit))+m("Cash",money(s.cash))+m("UPI",money(s.upi))+m("Credit",money(s.credit))+m("Transactions",String(s.tx))+m("Products",String(products.length))+m("Low Stock",String(low.length))+'</div><div class="panel"><h3>Reconciliation</h3><p>Cash + UPI + Credit: <b>'+money(s.cash+s.upi+s.credit)+'</b></p><p>Recorded sales: <b>'+money(s.sales)+'</b></p><p class="'+(Math.abs(s.cash+s.upi+s.credit-s.sales)<.01?"positive":"negative")+'">'+(Math.abs(s.cash+s.upi+s.credit-s.sales)<.01?"Balanced":"Difference: "+money(s.cash+s.upi+s.credit-s.sales))+'</p></div></section>';
}

function reports(){
 const recent=daily.filter(x=>x.business_date).slice(0,7);
 const selected=reportDate?daily.find(x=>x.business_date===reportDate):null;
 const total=lifetime||{};
 const row=(d:any)=>'<tr><td>'+d.business_date+'</td><td>'+String(d.total_transactions||0)+'</td><td>'+money(d.total_revenue)+'</td><td>'+money(d.cash_sales)+'</td><td>'+money(d.upi_sales)+'</td><td>'+money(d.credit_sales)+'</td><td>'+money(d.total_profit)+'</td><td>'+money(d.cash_profit)+'</td><td>'+money(d.upi_profit)+'</td><td>'+money(d.credit_profit)+'</td><td>'+money(d.purchase_cash)+'</td><td>'+money(d.purchase_upi)+'</td><td>'+money(d.purchase_credit)+'</td><td>'+money(d.debtor_payment_total)+'</td><td>'+money(d.debtor_payment_cash)+'</td><td>'+money(d.debtor_payment_upi)+'</td></tr>';
 const rows=selected?[selected]:recent;
 return '<section class="page"><h2>Reports</h2><div class="metrics">'+m("Lifetime Sales",money(total.lifetime_sales))+m("Lifetime Purchases",money(total.lifetime_purchases))+m("Lifetime Profit",money(total.lifetime_profit))+'</div><div class="panel"><div class="section-head"><h3>Date-wise Financials</h3><label class="date-inline">Search date<input id="reportDate" type="date" value="'+esc(reportDate)+'"></label></div><p class="muted">Latest 7 days are shown by default. Search any date for its permanent aggregate.</p><div class="table-wrap swipeable"><table><thead><tr><th>Date</th><th>Txn</th><th>Sales</th><th>Cash</th><th>UPI</th><th>Credit</th><th>Profit</th><th>Cash Profit</th><th>UPI Profit</th><th>Credit Profit</th><th>Cash Purchase</th><th>UPI Purchase</th><th>Debt Purchase</th><th>Debtor Paid</th><th>Paid Cash</th><th>Paid UPI</th></tr></thead><tbody>'+rows.map(row).join("")+(rows.length?"":'<tr><td colspan="16" class="muted">No financial aggregate for this date.</td></tr>')+'</tbody></table></div></div></section>';
}

function workers(){
 const rows=workersRows.filter(x=>x.role==="worker");
 return '<section class="page"><h2>Workers</h2><div class="panel"><div class="section-head"><p class="muted">Owner-only worker list and approval status.</p><span class="badge">'+rows.length+' worker(s)</span></div><div class="table-wrap"><table><thead><tr><th>Name</th><th>Email</th><th>Status</th><th>Shop</th></tr></thead><tbody>'+rows.map(w=>'<tr><td>'+esc(w.full_name)+'</td><td>'+esc(w.email)+'</td><td>'+(w.is_active?'<span class="badge ok">Approved</span>':'<span class="badge warn">Pending</span>')+'</td><td>'+esc(w.shop_id||"")+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="4" class="muted">No workers found.</td></tr>')+'</tbody></table></div></div></section>';
}

function audit(){
 const d=auditDate||localDate();
 const rows=auditRows.filter(a=>localDate(new Date(a.created_at))===d);
 return '<section class="page"><div class="page-head"><div><h2>Audit</h2><p class="muted">Owner only · retained audit detail is available for 30 days.</p></div><div class="action-row"><label class="date-inline">Date<input id="auditDate" type="date" value="'+esc(auditDate||localDate())+'"></label><button id="deleteAuditDate" class="ghost">Delete This Date</button></div></div><div class="panel"><div class="table-wrap"><table><thead><tr><th>Date</th><th>Actor</th><th>Action</th><th>Entity</th></tr></thead><tbody>'+rows.map(a=>'<tr><td>'+fmt(a.created_at)+'</td><td>'+esc(a.profiles?.full_name||a.actor_id||"System")+'</td><td>'+esc(a.action)+'</td><td>'+esc(a.entity_type)+'</td></tr>').join("")+(rows.length?"":'<tr><td colspan="4" class="muted">No audit records for this date.</td></tr>')+'</tbody></table></div></div></section>';
}

function settingsView(){
 const owner=profile?.role==="owner";
 return '<section class="page"><h2>Settings</h2><div class="panel"><form id="settingsForm" class="form-grid"><label>Shop name<input name="shop_name" value="'+esc(settings.shop_name)+'" required></label><label>Shop ID<input value="'+esc(settings.shop_id||profile?.shop_id||"Not configured")+'" readonly></label><label>Currency<input name="currency" value="'+esc(settings.currency||"INR")+'" required></label><label>Timezone<input name="timezone" value="'+esc(settings.timezone||"Asia/Kolkata")+'" required></label><label>Dashboard reset time<div class="form-grid"><select name="resetHour">'+[1,2,3,4,5,6,7,8,9,10,11,12].map(h=>'<option value="'+h+'">'+h+'</option>').join("")+'</select><select name="resetMinute">'+Array.from({length:60},(_,i)=>'<option value="'+String(i).padStart(2,"0")+'">'+String(i).padStart(2,"0")+'</option>').join("")+'</select><select name="resetPeriod"><option>AM</option><option>PM</option></select></div><span class="tiny">12-hour AM/PM</span></label><label class="check"><input type="checkbox" name="allow_below_cost_sales" '+(settings.allow_below_cost_sales!==false?"checked":"")+'> Allow sales below purchase cost</label><label class="check"><input type="checkbox" name="allow_zero_price_sales" '+(settings.allow_zero_price_sales!==false?"checked":"")+'> Allow zero-price/free sales</label><label class="check"><input type="checkbox" name="workers_can_modify_selling_price" '+(settings.workers_can_modify_selling_price===true?"checked":"")+'> Workers can modify selling price</label><div class="full"><button class="primary">Save Settings</button></div></form></div><div class="panel"><h3>Supabase Project</h3><p class="muted">Owner can verify or change the connected project.</p><div class="action-row"><button id="verifyDb" class="ghost" type="button">Verify Database</button><button id="downloadSqlSettingsBtn" class="ghost" type="button">Download SQL</button><button id="changeDb" class="ghost" type="button">Change Supabase Project</button></div></div><div class="panel"><h3>Backup / Report</h3><p class="muted">Owner-only export tools.</p><div class="action-row"><button id="exportBtn" class="ghost" type="button">Export Shop Data (JSON)</button><button id="downloadReport" class="ghost" type="button">Download All Report</button><button id="clearAll" class="ghost" type="button">Clear All Transaction Data</button></div></div><div class="panel"><h3>Shop ID</h3><button id="shopIdCopy" class="ghost" type="button">Copy Shop ID</button></div><div class="panel"><h3>Storage Retention</h3><p>Sales details: 90 days · Purchase details: 1 year · Audit: 30 days · Paid customer-credit detail: 7 days. Permanent aggregates remain. Pre-stock records are excluded from purchase history/financial reports.</p></div></section>';
}

async function saveSale(item:any,mode:string,cash:number,upi:number,credit:number,creditorId:string|null){
 if(demo){const p=products.find(x=>x.id===item.product_id);if(!p)throw new Error("Product not found");const total=item.quantity_base*item.selling_price_per_base_unit;sales.unshift({...item,id:"demo-sale-"+Date.now(),sold_at:new Date().toISOString(),worker_id:profile!.id,total_sale:total,gross_profit:(item.selling_price_per_base_unit-p.purchase_price_per_base_unit)*item.quantity_base,cash_amount:cash,upi_amount:upi,credit_amount:credit,payment_mode:mode,voided:false,transaction_id:"demo-tx-"+Date.now(),products:{name:p.name},profiles:{full_name:profile!.full_name}});p.current_stock_base-=item.quantity_base;if(credit>0&&creditorId)ledger.unshift({id:"demo-ledger-"+Date.now(),creditor_id:creditorId,type:"credit_sale",amount:credit,payment_mode:mode,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}});return}
 const r=await supabase!.rpc("complete_cart_sale",{p_worker_id:profile!.id,p_items:[item],p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi,p_credit_amount:credit,p_creditor_id:creditorId});if(r.error)throw r.error;
}

function bindSale(){
 const f=document.querySelector<HTMLFormElement>("#saleForm")!,sel=f.elements.namedItem("product") as HTMLSelectElement,qty=f.elements.namedItem("qty") as HTMLInputElement,price=f.elements.namedItem("price") as HTMLInputElement,unit=f.elements.namedItem("unit") as HTMLSelectElement,mode=f.elements.namedItem("mode") as HTMLSelectElement;
 const update=()=>{const p=products.find(x=>x.id===sel.value);if(!p)return;price.value=String(p.selling_price_per_base_unit);price.readOnly=profile?.role==="worker"&&settings.workers_can_modify_selling_price!==true;unit.disabled=p.unit_type==="piece";unit.value=p.unit_type==="piece"?"piece":"grams";const n=Number(qty.value)||0,base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n,total=base*p.selling_price_per_base_unit;document.querySelector("#saleTotal")!.textContent="Total: "+money(total);document.querySelectorAll<HTMLElement>("#saleProducts .product-card").forEach(x=>x.classList.toggle("selected",x.dataset.product===p.id));if(mode.value==="cash"){(f.elements.namedItem("cash") as HTMLInputElement).value=total.toFixed(2)}if(mode.value==="upi"){(f.elements.namedItem("upi") as HTMLInputElement).value=total.toFixed(2)}};
 const renderMatches=(q:string)=>{const root=document.querySelector("#saleProducts")!;const query=q.trim().toLowerCase();const matches=query?products.filter(p=>p.name.toLowerCase().includes(query)):[];root.innerHTML=matches.map(p=>'<button class="product-card" data-product="'+p.id+'"><b>'+esc(p.name)+'</b><span>'+p.current_stock_base+' available</span><strong>'+money(p.selling_price_per_base_unit)+'</strong></button>').join("")+(query&&!matches.length?'<div class="notice full">No matching product.</div>':"");root.querySelectorAll<HTMLElement>("[data-product]").forEach(x=>x.addEventListener("click",()=>{sel.value=x.dataset.product!;update()}))};
 document.querySelector("#saleSearchBtn")?.addEventListener("click",()=>renderMatches((document.querySelector("#saleSearch") as HTMLInputElement).value));
 document.querySelector("#saleSearch")?.addEventListener("input",e=>renderMatches((e.target as HTMLInputElement).value));
 sel.addEventListener("change",update);qty.addEventListener("input",update);price.addEventListener("input",update);unit.addEventListener("change",update);
 document.querySelector("#saleProducts")?.addEventListener("click",e=>{const b=(e.target as HTMLElement).closest<HTMLElement>("[data-product]");if(b){sel.value=b.dataset.product!;update()}});
 const saleCreditor=f.elements.namedItem("creditor") as HTMLSelectElement;
saleCreditor.addEventListener("change",async()=>{if(saleCreditor.value!=="__new__")return;const n=prompt("Creditor name");if(!n?.trim()){saleCreditor.value="";return}const mbl=prompt("Creditor mobile number");if(!mbl?.trim()){saleCreditor.value="";return}try{const c=await createCreditor(n.trim(),mbl.trim());render();notify("Creditor registered. Select it for the sale.","success")}catch(err){saleCreditor.value="";notify(err instanceof Error?err.message:String(err),"error")}});
mode.addEventListener("change",()=>{const v=mode.value,split=v==="split"||v==="credit_split",cr=v==="credit"||v==="credit_split";document.querySelector("#cashBox")?.classList.toggle("hidden",!split);document.querySelector("#upiBox")?.classList.toggle("hidden",!split);document.querySelector("#creditBox")?.classList.toggle("hidden",v!=="credit_split");document.querySelector("#creditorBox")?.classList.toggle("hidden",!cr);update()});update();
 f.addEventListener("submit",async e=>{e.preventDefault();const p=products.find(x=>x.id===sel.value)!;const n=Number(qty.value),base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n,total=base*Number(price.value),v=mode.value;let cash=Number((f.elements.namedItem("cash") as HTMLInputElement).value)||0,upi=Number((f.elements.namedItem("upi") as HTMLInputElement).value)||0,credit=Number((f.elements.namedItem("credit") as HTMLInputElement).value)||0;const cr=(f.elements.namedItem("creditor") as HTMLSelectElement).value||null;if(!n||base<=0||base>p.current_stock_base)return notify("Invalid quantity or insufficient stock.","error");if(v==="cash"){cash=total;upi=0;credit=0}if(v==="upi"){cash=0;upi=total;credit=0}if(v==="credit"){cash=0;upi=0;credit=total}if(v==="split"&&Math.abs(cash+upi-total)>.01)return notify("Cash + UPI must equal total.","error");if(v==="credit_split"&&(credit<=0||Math.abs(cash+upi+credit-total)>.01))return notify("Cash + UPI + Credit must equal total.","error");if((v==="credit"||v==="credit_split")&&!cr)return notify("Select a creditor.","error");try{await saveSale({product_id:p.id,quantity_base:base,quantity_display:n,sold_unit:unit.value,selling_price_per_base_unit:Number(price.value)},v,cash,upi,credit,cr);notify("Sale completed.","success");await loadData();render()}catch(err){notify(err instanceof Error?err.message:String(err),"error")}})
}

function bindCart(){
 const add=document.querySelector<HTMLFormElement>("#cartAdd")!;
 const sel=add.elements.namedItem("product") as HTMLSelectElement,qty=add.elements.namedItem("qty") as HTMLInputElement,unit=add.elements.namedItem("unit") as HTMLSelectElement,price=add.elements.namedItem("price") as HTMLInputElement;
 const update=()=>{const p=products.find(x=>x.id===sel.value);if(p){price.value=String(p.selling_price_per_base_unit);unit.value=p.unit_type==="piece"?"piece":"grams";const n=Number(qty.value)||0,base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n;document.querySelector("#cartPreview")!.textContent="Preview: "+p.name+" × "+n+" = "+money(base*Number(price.value));}};
 const renderMatches=(q:string)=>{const root=document.querySelector("#cartProducts")!,query=q.trim().toLowerCase(),matches=query?products.filter(p=>p.name.toLowerCase().includes(query)):[];root.innerHTML=matches.map(p=>'<button type="button" class="product-card" data-cart-product="'+p.id+'"><b>'+esc(p.name)+'</b><span>'+p.current_stock_base+' available</span><strong>'+money(p.selling_price_per_base_unit)+'</strong></button>').join("")+(query&&!matches.length?'<div class="notice full">No matching product.</div>':"");root.querySelectorAll<HTMLElement>("[data-cart-product]").forEach(x=>x.addEventListener("click",()=>{sel.value=x.dataset.cartProduct!;update()}))};
 document.querySelector("#cartSearchBtn")?.addEventListener("click",()=>renderMatches((document.querySelector("#cartSearch") as HTMLInputElement).value));
 document.querySelector("#cartSearch")?.addEventListener("input",e=>renderMatches((e.target as HTMLInputElement).value));
 sel.addEventListener("change",update);qty.addEventListener("input",update);unit.addEventListener("change",update);price.addEventListener("input",update);update();
 add.addEventListener("submit",e=>{e.preventDefault();const p=products.find(x=>x.id===sel.value)!;const n=Number(qty.value),base=p.unit_type==="piece"?n:unit.value==="kg"?n*1000:n;if(!n||base<=0||base>p.current_stock_base)return notify("Invalid quantity or insufficient stock.","error");cartItems.push({product_id:p.id,quantity_base:base,quantity_display:n,sold_unit:unit.value,selling_price_per_base_unit:Number(price.value),product_name_snapshot:p.name,purchase_price_per_base_unit:p.purchase_price_per_base_unit});notify("Added to cart.","success");render()});
 document.querySelectorAll<HTMLButtonElement>(".delete-cart").forEach(b=>b.addEventListener("click",()=>{cartItems.splice(Number(b.dataset.i),1);render()}));
 document.querySelectorAll<HTMLButtonElement>(".edit-cart").forEach(b=>b.addEventListener("click",()=>{const i=Number(b.dataset.i),x=cartItems[i],p=products.find(p=>p.id===x.product_id)!;const q=Number(prompt("Quantity",String(x.quantity_display)));if(!q||q<=0)return;const base=p.unit_type==="piece"?q:x.sold_unit==="kg"?q*1000:q;if(base>p.current_stock_base)return notify("Insufficient stock.","error");const oldTotal=base*Number(x.selling_price_per_base_unit);const editedTotal=Number(prompt("Total money for this item",oldTotal.toFixed(2)));if(!Number.isFinite(editedTotal)||editedTotal<0)return;x.quantity_display=q;x.quantity_base=base;x.selling_price_per_base_unit=base>0?editedTotal/base:0;render()}));
 const pay=document.querySelector<HTMLFormElement>("#cartPay")!,mode=pay.elements.namedItem("mode") as HTMLSelectElement,cash=pay.elements.namedItem("cash") as HTMLInputElement,upi=pay.elements.namedItem("upi") as HTMLInputElement,credit=pay.elements.namedItem("credit") as HTMLInputElement,total=cartItems.reduce((a,x)=>a+x.quantity_base*x.selling_price_per_base_unit,0);
 const toggle=()=>{const v=mode.value,split=v==="split"||v==="credit_split",cr=v==="credit"||v==="credit_split";document.querySelector("#cartCashBox")?.classList.toggle("hidden",!split);document.querySelector("#cartUpiBox")?.classList.toggle("hidden",!split);document.querySelector("#cartCreditBox")?.classList.toggle("hidden",v!=="credit_split");document.querySelector("#cartCreditorBox")?.classList.toggle("hidden",!cr);if(v==="cash"){cash.value=total.toFixed(2);upi.value="0";credit.value="0"}if(v==="upi"){cash.value="0";upi.value=total.toFixed(2);credit.value="0"}if(v==="credit"){cash.value="0";upi.value="0";credit.value=total.toFixed(2)}};
 const cartCreditor=pay.elements.namedItem("creditor") as HTMLSelectElement;
 cartCreditor.addEventListener("change",async()=>{if(cartCreditor.value!=="__new__")return;const n=prompt("Creditor name");if(!n?.trim()){cartCreditor.value="";return}const mbl=prompt("Creditor mobile number");if(!mbl?.trim()){cartCreditor.value="";return}try{await createCreditor(n.trim(),mbl.trim());render();notify("Creditor registered. Select it for the sale.","success")}catch(err){cartCreditor.value="";notify(err instanceof Error?err.message:String(err),"error")}});
 mode.addEventListener("change",toggle);toggle();
 pay.addEventListener("submit",async e=>{e.preventDefault();if(!cartItems.length)return notify("Add items first.","error");let c=Number(cash.value)||0,u=Number(upi.value)||0,cr=Number(credit.value)||0;if(mode.value==="cash"){c=total;u=0;cr=0}if(mode.value==="upi"){c=0;u=total;cr=0}if(mode.value==="credit"){c=0;u=0;cr=total}if(mode.value==="split"&&Math.abs(c+u-total)>.01)return notify("Cash + UPI must equal total.","error");if(mode.value==="credit_split"&&(cr<=0||Math.abs(c+u+cr-total)>.01))return notify("Cash + UPI + Credit must equal total.","error");const crSelect=pay.elements.namedItem("creditor") as HTMLSelectElement,crid=crSelect.value==="__new__"?null:crSelect.value||null;if((mode.value==="credit"||mode.value==="credit_split")&&!crid)return notify("Select a creditor.","error");try{if(demo){for(const x of cartItems){const p=products.find(p=>p.id===x.product_id)!;const itemTotal=x.quantity_base*x.selling_price_per_base_unit;p.current_stock_base-=x.quantity_base;sales.unshift({...x,id:"cart-"+Date.now()+Math.random(),sold_at:new Date().toISOString(),worker_id:profile!.id,total_sale:itemTotal,gross_profit:(x.selling_price_per_base_unit-p.purchase_price_per_base_unit)*x.quantity_base,cash_amount:c*(itemTotal/total),upi_amount:u*(itemTotal/total),credit_amount:cr*(itemTotal/total),payment_mode:mode.value,voided:false,products:{name:p.name},profiles:{full_name:profile!.full_name}})}if(cr>0&&crid)ledger.unshift({id:"cart-ledger-"+Date.now(),creditor_id:crid,type:"credit_sale",amount:cr,payment_mode:mode.value,created_at:new Date().toISOString(),worker_id:profile!.id,profiles:{full_name:profile!.full_name}})}else{const r=await supabase!.rpc("complete_cart_sale",{p_worker_id:profile!.id,p_items:cartItems,p_payment_mode:mode.value,p_cash_amount:c,p_upi_amount:u,p_credit_amount:cr,p_creditor_id:crid});if(r.error)throw r.error}cartItems=[];notify("Cart sale completed.","success");await loadData();render()}catch(err){notify(err instanceof Error?err.message:String(err),"error")}})
}
function bindSettings(){
 document.querySelector("#settingsForm")?.addEventListener("submit",async e=>{e.preventDefault();const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),tz=String(fd.get("timezone")||"").trim();try{new Intl.DateTimeFormat("en-US",{timeZone:tz}).format()}catch{return notify("Invalid IANA timezone.","error")}const h=Number(fd.get("resetHour")||12),mi=String(fd.get("resetMinute")||"00"),period=String(fd.get("resetPeriod")||"AM"),h24=period==="AM"?(h===12?0:h):(h===12?12:h+12),next={shop_name:String(fd.get("shop_name")),currency:String(fd.get("currency")),timezone:tz,dashboard_reset_time:String(h24).padStart(2,"0")+":"+mi,allow_below_cost_sales:fd.get("allow_below_cost_sales")==="on",allow_zero_price_sales:fd.get("allow_zero_price_sales")==="on",workers_can_modify_selling_price:fd.get("workers_can_modify_selling_price")==="on"};if(demo){settings={...settings,...next};notify("Settings saved.","success");render();return}const r=await supabase!.from("shop_settings").update({...next,updated_at:new Date().toISOString()}).eq("id",1);if(r.error)return notify(r.error.message,"error");settings={...settings,...next};notify("Settings saved.","success");render()});
 document.querySelector("#verifyDb")?.addEventListener("click",async()=>{if(demo)return notify("Demo database check passed.","success");if(!supabase)return notify("Supabase is not connected.","error");const r=await supabase.rpc("verify_shop_management",{p_expected_shop_id:profile?.shop_id||""});if(r.error)return notify(r.error.message,"error");notify(r.data?.ok?"Database verification passed.":"Missing: "+(r.data?.missing||[]).join(", "),"success")});
 document.querySelector("#downloadSqlSettingsBtn")?.addEventListener("click",async()=>{try{const r=await fetch("/shop-management-final.sql");if(!r.ok)throw new Error("SQL file unavailable.");downloadText("shop-management-final.sql",await r.text());notify("SQL downloaded.","success")}catch(e){notify(e instanceof Error?e.message:String(e),"error")}});
 document.querySelector("#changeDb")?.addEventListener("click",()=>login("Enter the new Supabase project details below."));
 document.querySelector("#shopIdCopy")?.addEventListener("click",async()=>{const id=String(settings.shop_id||profile?.shop_id||"");if(!id)return notify("Shop ID is not configured.","error");try{await navigator.clipboard.writeText(id);notify("Shop ID copied.","success")}catch{notify("Copy failed.","error")}});
 document.querySelector("#exportBtn")?.addEventListener("click",async()=>await downloadText("shop-data-"+localDate()+".json",JSON.stringify({exported_at:new Date().toISOString(),settings,products,sales,purchases,creditors,ledger,debtors,debtorLedger,daily,lifetime,audit:auditRows},null,2)));
 document.querySelector("#downloadReport")?.addEventListener("click",async()=>{try{
 const cutoffDate=new Date(Date.now()-89*864e5);
 let dailyRows:any[]=[];
 let reportProducts:any[]=products;
 if(!demo&&supabase){
  const [df,pr]=await Promise.all([
   supabase.from("daily_financial_summaries").select("*").gte("business_date",localDate(cutoffDate)).lte("business_date",localDate()).order("business_date",{ascending:false}),
   supabase.from("products").select("*").eq("is_active",true).order("name")
  ]);
  dailyRows=df.data||[];reportProducts=pr.data||[];
 }else{
  dailyRows=daily.filter(x=>new Date(x.business_date+"T00:00:00").getTime()>=cutoffDate.getTime()).sort((a,b)=>String(b.business_date).localeCompare(String(a.business_date)));
 }
 const moneyTxt=(n:any)=>new Intl.NumberFormat("en-IN",{minimumFractionDigits:2,maximumFractionDigits:2}).format(Number(n)||0);
 const pad=(v:any,n:number)=>String(v??"").padEnd(n," ");
 const lines:string[]=[
  "SHOP MANAGEMENT — SIMPLE OWNER REPORT",
  "Generated: "+new Date().toLocaleString("en-IN",{dateStyle:"short",timeStyle:"medium"}),
  "",
  "1. CURRENT STOCK",
  "NO.   ITEM                        STOCK           PURCHASE PRICE    SALE PRICE",
  "--------------------------------------------------------------------------------------"
 ];
 reportProducts.forEach((p:any,i:number)=>{
  const stock=String(p.current_stock_base)+" "+(p.unit_type==="piece"?"pcs":"g");
  lines.push(pad(i+1,6)+pad(p.name,28)+pad(stock,16)+pad(settings.currency+" "+moneyTxt(p.purchase_price_per_base_unit),18)+settings.currency+" "+moneyTxt(p.selling_price_per_base_unit));
 });
 lines.push("","2. DAILY SALES — LAST 90 DAYS","DATE          TOTAL SALE        PROFIT            CASH              UPI","--------------------------------------------------------------------------------------");
 const byDate=new Map<string,any>();dailyRows.forEach((d:any)=>byDate.set(String(d.business_date),d));
 for(let i=0;i<90;i++){const dt=new Date();dt.setHours(0,0,0,0);dt.setDate(dt.getDate()-i);const date=localDate(dt),d=byDate.get(date)||{};lines.push(pad(date,14)+pad(settings.currency+" "+moneyTxt(d.total_revenue),18)+pad(settings.currency+" "+moneyTxt(d.total_profit),18)+pad(settings.currency+" "+moneyTxt(d.cash_sales),18)+settings.currency+" "+moneyTxt(d.upi_sales));}
 lines.push("","3. CREDITORS — OUTSTANDING","CREDITOR                        MOBILE            AMOUNT DUE","----------------------------------------------------------------------");
 const oc=creditors.map((c:any)=>({...c,balance:qBalance(c.id)})).filter((c:any)=>Number(c.balance)>0.01);
 if(!oc.length)lines.push("No outstanding creditors.");else oc.forEach((c:any)=>lines.push(pad(c.name,32)+pad(c.mobile||"",18)+settings.currency+" "+moneyTxt(c.balance)));
 lines.push("","4. DEBTORS — OUTSTANDING","DEBTOR                          MOBILE            AMOUNT DUE","----------------------------------------------------------------------");
 const od=debtors.map((d:any)=>({...d,balance:dBalance(d.id)})).filter((d:any)=>Number(d.balance)>0.01);
 if(!od.length)lines.push("No outstanding debtors.");else od.forEach((d:any)=>lines.push(pad(d.name,32)+pad(d.mobile||"",18)+settings.currency+" "+moneyTxt(d.balance)));
 lines.push("","5. 90-DAY DATE-WISE FINANCIAL REPORT","DATE          TXN    SALES            CASH             UPI              CREDIT           PROFIT           CASH PROFIT      UPI PROFIT","--------------------------------------------------------------------------------------------------------------------------------");
 dailyRows.forEach((d:any)=>lines.push(pad(d.business_date,14)+pad(d.total_transactions||0,7)+pad(moneyTxt(d.total_revenue),17)+pad(moneyTxt(d.cash_sales),17)+pad(moneyTxt(d.upi_sales),17)+pad(moneyTxt(d.credit_sales),17)+pad(moneyTxt(d.total_profit),17)+pad(moneyTxt(d.cash_profit),17)+moneyTxt(d.upi_profit)));
 lines.push("","Generated locally on this device. No report file is uploaded to Supabase Storage.");
 await downloadText("Shop_Report_All_"+localDate()+".txt",lines.join("\n"));
 notify("Complete shop report downloaded as TXT.","success");
}catch(err){notify(err instanceof Error?err.message:String(err),"error")}});
document.querySelector("#clearAll")?.addEventListener("click",async()=>{if(demo)return notify("Demo data is temporary; no real database was changed.","info");if(confirm("Clear transaction data? This is permanent.")){const r=await supabase!.rpc("clear_all_shop_data");if(r.error)return notify(r.error.message,"error");await loadData();render();notify("All transaction data cleared.","success")}});
}

function bind(){
 document.querySelectorAll<HTMLElement>("[data-nav]").forEach(x=>x.addEventListener("click",()=>{activeTab=x.dataset.nav||"dashboard";render()}));
 document.querySelector("#logout")?.addEventListener("click",async()=>{if(!demo)await supabase?.auth.signOut();profile=null;demo=false;demoReady=false;cartItems=[];activeTab="dashboard";login()});
 document.querySelector("#refresh")?.addEventListener("click",async()=>{await loadData();render()});
 if(activeTab==="sale")bindSale();
 if(activeTab==="cart")bindCart();
 if(activeTab==="creditors"&&typeof bindCreditors==="function")bindCreditors();
 if(activeTab==="debtors")bindDebtors();
 if(activeTab==="history")bindHistory();
 if(activeTab==="reports")document.querySelector("#reportDate")?.addEventListener("change",e=>{reportDate=(e.currentTarget as HTMLInputElement).value;render()});
 if(activeTab==="stock"){document.querySelector("#addPurchase")?.addEventListener("click",purchaseForm);document.querySelector("#addProduct")?.addEventListener("click",productForm)}
 if(activeTab==="settings")bindSettings();
}
function addSwipeHints(){
 document.querySelectorAll<HTMLElement>(".table-wrap,.seg,.bottom-nav").forEach(el=>{
  if(el.scrollWidth<=el.clientWidth+2)return;
  const wrap=el.classList.contains("bottom-nav")?el:el.parentElement||el;
  wrap.classList.add("swipe-host");
  const update=()=>{wrap.querySelectorAll<HTMLElement>(".swipe-arrow").forEach(x=>x.remove());const left=el.scrollLeft>2,right=el.scrollLeft<el.scrollWidth-el.clientWidth-2;const mk=(side:string,dir:number)=>{const b=document.createElement("button");b.type="button";b.className="swipe-arrow "+side;b.textContent=side==="left"?"‹":"›";b.title=side==="left"?"Swipe right":"Swipe left";b.addEventListener("click",e=>{e.preventDefault();e.stopPropagation();el.scrollBy({left:dir*Math.max(180,el.clientWidth*.7),behavior:"smooth"})});wrap.appendChild(b)};if(left)mk("left",-1);if(right)mk("right",1)};update();el.addEventListener("scroll",update,{passive:true});
 });
}
function render(){
 if(!profile){login();return}
 const oldNav=document.querySelector<HTMLElement>(".bottom-nav");if(oldNav)bottomNavScrollLeft=oldNav.scrollLeft;
 app.innerHTML=shell(activeTab);
 const view=document.querySelector("#view")!;
 view.innerHTML=activeTab==="dashboard"?dashboard():activeTab==="sale"?sale():activeTab==="cart"?cart():activeTab==="stock"?stock():activeTab==="creditors"?creditorsView():activeTab==="debtors"?debtorsView():activeTab==="history"?history():activeTab==="today"?today():activeTab==="reports"?reports():activeTab==="workers"?workers():activeTab==="audit"?audit():settingsView();
 bind();
 const newNav=document.querySelector<HTMLElement>(".bottom-nav");if(newNav){newNav.scrollLeft=bottomNavScrollLeft;newNav.addEventListener("scroll",()=>{bottomNavScrollLeft=newNav.scrollLeft},{passive:true})}
 addSwipeHints();
}

function login(msg=""){
 app.innerHTML='<div class="login"><div class="login-card"><div class="brand big">SHOP MANAGEMENT</div><h2>Storage Redesign Test</h2><p class="muted">Temporary test environment. Production app is untouched.</p>'+(msg?'<div class="notice danger">'+esc(msg)+'</div>':"")+'<button id="demoBtn" class="primary wide">🧪 Test Demo App</button><div class="divider">OR</div><form id="realLogin"><label>Supabase Project URL<input name="url" placeholder="https://xxxxx.supabase.co"></label><label>Publishable key<input name="key" placeholder="sb_publishable_..."></label><label>Email<input name="email" type="email"></label><label>Password<input name="password" type="password"></label><button class="ghost wide">Connect & Sign In</button></form><p class="tiny">Demo data is local only and will be removed before finalization.</p></div></div>';
 document.querySelector("#demoBtn")?.addEventListener("click",async()=>{initDemo();activeTab="dashboard";await loadData();render()});
 document.querySelector<HTMLFormElement>("#realLogin")?.addEventListener("submit",async e=>{e.preventDefault();const f=e.currentTarget as HTMLFormElement,fd=new FormData(f),url=String(fd.get("url")||"").trim(),key=String(fd.get("key")||"").trim(),email=String(fd.get("email")||"").trim(),password=String(fd.get("password")||"");if(!url||!key||!email||!password)return notify("Fill all fields.","error");supabase=createClient(url,key);const r=await supabase.auth.signInWithPassword({email,password});if(r.error)return login(r.error.message);localStorage.setItem(URL_KEY,url);localStorage.setItem(KEY_KEY,key);const p=await supabase.from("profiles").select("*").eq("id",r.data.user.id).single();if(p.error)return login(p.error.message);profile={...p.data,role:p.data.role as Role} as Profile;if(!profile.is_active)return login("Your account is awaiting approval.");demo=false;demoReady=false;await loadData();render()});
 const c=readConn();if(c.url&&c.key){(document.querySelector('input[name="url"]') as HTMLInputElement).value=c.url;(document.querySelector('input[name="key"]') as HTMLInputElement).value=c.key}
}
connect();login();
