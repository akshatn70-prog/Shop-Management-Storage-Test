import type { SupabaseClient } from "@supabase/supabase-js";
import { Capacitor } from "@capacitor/core";
import { ShopDownloads } from "@shop-management/downloads";

type CartItem = {
  product_id: string;
  quantity_base: number;
  quantity_display: number;
  sold_unit: string;
  selling_price_per_base_unit: number;
};

type FeatureContext = {
  getSupabase: () => SupabaseClient | null;
  getProfile: () => any;
  getProducts: () => any[];
  getCreditors: () => any[];
  getCreditLedger: () => any[];
  getSettings: () => any;
  money: (n: number) => string;
  escapeHtml: (s: string) => string;
  notify: (message: string, kind?: "success"|"error"|"info") => void;
  refresh: () => Promise<void>;
  renderDashboard: () => void;
  localDate: () => string;
  businessDayBounds: () => {start:string;end:string};
  formatDateTime: (value: string) => string;
  saleQty: (sale: any) => string;
};

export function createCartCreditFeature(ctx: FeatureContext) {
  let cartItems: CartItem[] = [];
  let cartStage: "edit" | "preview" = "edit";

  const product = (id: string) => ctx.getProducts().find(p => p.id === id);
  const creditorBalance = (id: string) => ctx.getCreditLedger().filter(x => x.creditor_id === id).reduce((sum,x) => {
    const amount = Number(x.amount || 0);
    return sum + (x.type === "credit_sale" ? amount : x.type === "payment_received" ? -amount : amount);
  }, 0);
  const cartTotal = () => cartItems.reduce((sum,item) => {
    const p=product(item.product_id);
    if (!p) return sum;
    return sum + (p.unit_type==="piece" ? item.quantity_base*item.selling_price_per_base_unit : (item.quantity_base/1000)*item.selling_price_per_base_unit);
  },0);

  function renderCartPanel() {
    const products=ctx.getProducts(), creditors=ctx.getCreditors(), profile=ctx.getProfile(), settings=ctx.getSettings();
    if (cartStage==="preview") {
      return `
        <div class="section-head"><h2>Final Bill Preview</h2><button id="editCartBtn" class="ghost">Edit Cart</button></div>
        <div class="notice"><b>Total:</b> ${ctx.money(cartTotal())}</div>
        <div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty</th><th>Unit price</th><th>Total</th></tr></thead><tbody>
          ${cartItems.map(item=>{const p=product(item.product_id);const total=p?.unit_type==="piece"?item.quantity_base*item.selling_price_per_base_unit:(item.quantity_base/1000)*item.selling_price_per_base_unit;return `<tr><td>${ctx.escapeHtml(p?.name||"Product")}</td><td>${item.quantity_display} ${item.sold_unit==="kg"?"kg":item.sold_unit==="grams"?"g":"pcs"}</td><td>${ctx.money(item.selling_price_per_base_unit)}</td><td>${ctx.money(total)}</td></tr>`;}).join("")}
        </tbody></table></div>
        <form id="cartPaymentForm" class="form-grid">
          <label>Payment<select name="payment_mode"><option value="cash">Cash</option><option value="upi">UPI</option><option value="split">Cash + UPI</option><option value="credit">Credit</option><option value="credit_split">Credit + Cash + UPI</option></select></label>
          <label id="cartCashWrap" class="hidden">Cash amount<input name="cash_amount" type="number" min="0" step="any" value="0"></label>
          <label id="cartUpiWrap" class="hidden">UPI amount<input name="upi_amount" type="number" min="0" step="any" value="0"></label>
          <label id="cartCreditWrap" class="hidden">Credit amount<input name="credit_amount" type="number" min="0" step="any" value="0"></label>
          <label id="cartCreditorWrap" class="hidden">Creditor<select name="creditor_id"><option value="">Select creditor</option>
            ${creditors.map(x=>`<option value="${x.id}">${ctx.escapeHtml(x.name)} — ${ctx.escapeHtml(x.mobile)} (Balance ${ctx.money(creditorBalance(x.id))})</option>`).join("")}
          </select><button id="newCartCreditorBtn" type="button" class="ghost">+ New Creditor</button></label>
          <div class="full"><button class="primary" type="submit">Confirm Sale</button></div>
        </form>`;
    }
    return `
      <div class="section-head"><h2>🛒 Cart</h2><span class="badge">${cartItems.length} item${cartItems.length===1?"":"s"}</span></div>
      <p class="muted">Add products here. Nothing changes stock or accounting until the final Confirm Sale.</p>
      <form id="cartAddForm" class="form-grid">
        <label>Search product<input id="cartProductSearch" type="search" placeholder="Search by product name..."></label>
        <label>Product<select id="cartProductSelect" name="product_id" required>${products.map(p=>`<option value="${p.id}">${ctx.escapeHtml(p.name)} — ${ctx.escapeHtml(String(p.current_stock_base))} available</option>`).join("")}</select></label>
        <label>Quantity<input name="quantity" type="number" min="0" step="any" required></label>
        <label>Sold in<select name="sold_unit"></select></label>
        <label>Selling price<input name="price" type="number" min="0" step="any" required></label>
        <div class="full"><button class="primary" type="submit">Add</button><button id="cartDoneBtn" type="button" class="ghost">Done</button></div>
      </form>
      <div class="section-head"><h3>Cart Items</h3><span class="muted">Unlimited items</span></div>
      <div class="table-wrap"><table><thead><tr><th>Product</th><th>Qty</th><th>Unit price</th><th>Total</th><th></th></tr></thead><tbody>
        ${cartItems.map((item,i)=>{const p=product(item.product_id);const total=p?.unit_type==="piece"?item.quantity_base*item.selling_price_per_base_unit:(item.quantity_base/1000)*item.selling_price_per_base_unit;return `<tr><td>${ctx.escapeHtml(p?.name||"Product")}</td><td>${item.quantity_display} ${item.sold_unit==="kg"?"kg":item.sold_unit==="grams"?"g":"pcs"}</td><td>${ctx.money(item.selling_price_per_base_unit)}</td><td>${ctx.money(total)}</td><td><button class="smallbtn edit-cart" data-index="${i}">Edit</button> <button class="smallbtn delete-cart" data-index="${i}">Delete</button></td></tr>`;}).join("") || '<tr><td colspan="5" class="muted">Cart is empty.</td></tr>'}
      </tbody></table></div>`;
  }

  function renderCreditorsPanel() {
    const creditors=ctx.getCreditors();
    return `
      <div class="section-head"><h2>Creditors</h2><button id="addCreditorBtn" class="primary">+ Add Creditor</button></div>
      <label class="product-search-label">Search creditor<input id="creditorSearch" type="search" placeholder="Name or mobile..."></label>
      <div class="table-wrap"><table><thead><tr><th>Name</th><th>Mobile</th><th>Outstanding</th><th>Actions</th></tr></thead><tbody>
        ${creditors.map(c=>`<tr class="creditor-row" data-search="${ctx.escapeHtml((c.name+" "+c.mobile).toLowerCase())}"><td>${ctx.escapeHtml(c.name)}</td><td>${ctx.escapeHtml(c.mobile)}</td><td class="${creditorBalance(c.id)>0?"negative":"positive"}">${ctx.money(creditorBalance(c.id))}</td><td><button class="smallbtn receive-credit" data-id="${c.id}">Receive Payment</button> <button class="smallbtn view-credit-history" data-id="${c.id}">History</button></td></tr>`).join("") || '<tr><td colspan="4" class="muted">No creditors yet.</td></tr>'}
      </tbody></table></div>
      <div id="creditorHistoryPanel"></div>`;
  }

  function dailySummaryData() {
    const sales=ctx.getProducts() && (window as any).__shopManagementTodaySales ? (window as any).__shopManagementTodaySales as any[] : [];
    const ledger=ctx.getCreditLedger(), bounds=ctx.businessDayBounds();
    const profile=ctx.getProfile();
    const collections=ledger.filter(x=>x.type==="payment_received" && x.created_at>=bounds.start && x.created_at<bounds.end && (profile?.role==="owner" || x.worker_id===profile?.id));
    const revenue=sales.filter(s=>!s.voided).reduce((a,s)=>a+Number(s.total_sale||0),0);
    const profit=sales.filter(s=>!s.voided).reduce((a,s)=>a+Number(s.gross_profit||0),0);
    const salesCash=sales.filter(s=>!s.voided).reduce((a,s)=>a+Number(s.cash_amount||0),0);
    const salesUpi=sales.filter(s=>!s.voided).reduce((a,s)=>a+Number(s.upi_amount||0),0);
    const creditSales=sales.filter(s=>!s.voided&&(s.payment_mode==="credit"||s.payment_mode==="credit_split")).reduce((a,s)=>a+Math.max(0,Number(s.total_sale||0)-Number(s.cash_amount||0)-Number(s.upi_amount||0)),0);
    const creditCash=collections.reduce((a,x)=>a+Number(x.cash_amount||0),0);
    const creditUpi=collections.reduce((a,x)=>a+Number(x.upi_amount||0),0);
    return {sales:sales.filter(s=>!s.voided),collections,revenue,profit,salesCash,salesUpi,creditSales,creditCash,creditUpi};
  }

  function renderDailySummaryPanel() {
    const d=dailySummaryData();
    return `
      <div class="section-head"><h2>Daily Summary</h2><button id="downloadDailySummaryBtn" class="primary">Download TXT</button></div>
      <p class="muted">Business day: ${ctx.escapeHtml(ctx.localDate())}. Credit collections are shown separately and are not counted as new sales revenue.</p>
      <section class="hero-grid">
        <div class="metric"><div class="metric-label">Transactions</div><div class="metric-value">${new Set(d.sales.map(s=>s.transaction_id||s.id)).size}</div></div>
        <div class="metric"><div class="metric-label">Revenue</div><div class="metric-value">${ctx.money(d.revenue)}</div></div>
        <div class="metric"><div class="metric-label">Gross Profit</div><div class="metric-value ${d.profit>=0?"positive":"negative"}">${ctx.money(d.profit)}</div></div>
        <div class="metric"><div class="metric-label">Sales Cash</div><div class="metric-value">${ctx.money(d.salesCash)}</div></div>
        <div class="metric"><div class="metric-label">Sales UPI</div><div class="metric-value">${ctx.money(d.salesUpi)}</div></div>
        <div class="metric"><div class="metric-label">Credit Sales</div><div class="metric-value">${ctx.money(d.creditSales)}</div></div>
        <div class="metric"><div class="metric-label">Credit Cash Collected</div><div class="metric-value">${ctx.money(d.creditCash)}</div></div>
        <div class="metric"><div class="metric-label">Credit UPI Collected</div><div class="metric-value">${ctx.money(d.creditUpi)}</div></div>
      </section>
      <h3 class="subhead">Sold items</h3>
      <div class="table-wrap"><table><thead><tr><th>Time</th><th>Worker</th><th>Product</th><th>Qty</th><th>Revenue</th><th>Payment</th></tr></thead><tbody>
        ${d.sales.map(s=>`<tr><td>${ctx.formatDateTime(s.sold_at)}</td><td>${ctx.escapeHtml(s.profiles?.full_name||"")}</td><td>${ctx.escapeHtml(s.products?.name||s.product_name_snapshot||"Deleted product")}</td><td>${ctx.saleQty(s)}</td><td>${ctx.money(Number(s.total_sale||0))}</td><td>${ctx.escapeHtml(String(s.payment_mode||"cash").toUpperCase())}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">No sales today.</td></tr>'}
      </tbody></table></div>
      <h3 class="subhead">Credit collections today</h3>
      <div class="table-wrap"><table><thead><tr><th>Time</th><th>Creditor</th><th>Amount</th><th>Mode</th><th>Received by</th></tr></thead><tbody>
        ${d.collections.map(x=>{const cr=ctx.getCreditors().find(c=>c.id===x.creditor_id);return `<tr><td>${ctx.formatDateTime(x.created_at)}</td><td>${ctx.escapeHtml(cr?.name||"")}</td><td>${ctx.money(Number(x.amount||0))}</td><td>${ctx.escapeHtml(String(x.payment_mode||"").toUpperCase())}</td><td>${ctx.escapeHtml(x.profiles?.full_name||"")}</td></tr>`;}).join("") || '<tr><td colspan="5" class="muted">No credit collections today.</td></tr>'}
      </tbody></table></div>`;
  }

  async function downloadDailySummary() {
    const d=dailySummaryData(), settings=ctx.getSettings();
    const workers=new Map<string,number>();
    d.sales.forEach(s=>{const n=s.profiles?.full_name||"Worker";workers.set(n,(workers.get(n)||0)+Number(s.total_sale||0));});
    const lines=[
      "================================",
      settings.shop_name||"SHOP MANAGEMENT",
      "DAILY SUMMARY",
      "================================",
      "Business day: "+ctx.localDate(),"",
      "SALES",
      "Transactions: "+new Set(d.sales.map(s=>s.transaction_id||s.id)).size,
      "Sale lines: "+d.sales.length,
      "Revenue: "+ctx.money(d.revenue),
      "Gross Profit: "+ctx.money(d.profit),"",
      "PAYMENTS FROM SALES",
      "Cash: "+ctx.money(d.salesCash),
      "UPI: "+ctx.money(d.salesUpi),
      "Credit Sales: "+ctx.money(d.creditSales),"",
      "CREDIT PAYMENTS RECEIVED",
      "Cash: "+ctx.money(d.creditCash),
      "UPI: "+ctx.money(d.creditUpi),
      "Total Credit Collected: "+ctx.money(d.creditCash+d.creditUpi),"",
      "WORKER SALES",
      ...[...workers.entries()].map(([n,v])=>n+": "+ctx.money(v)),"",
      "================================"
    ].join("\n");
    const fileName="ShopSummary_"+ctx.localDate()+".txt";
    try {
      if(Capacitor.getPlatform()==="android") {
        await ShopDownloads.saveTextToDownloads({fileName,content:lines});
        ctx.notify("Summary saved to Android Downloads.","success");
      } else {
        const blob=new Blob([lines],{type:"text/plain;charset=utf-8"}),url=URL.createObjectURL(blob),a=document.createElement("a");
        a.href=url;a.download=fileName;a.click();URL.revokeObjectURL(url);
        ctx.notify("Summary downloaded.","success");
      }
    } catch(err) { ctx.notify(err instanceof Error?err.message:String(err),"error"); }
  }

  async function addCreditor() {
    const supabase=ctx.getSupabase(); if(!supabase)return;
    const name=prompt("Creditor name:"),mobile=prompt("Mobile number:");
    if(!name?.trim()||!mobile?.trim())return;
    const {error}=await supabase.rpc("get_or_create_creditor",{p_name:name.trim(),p_mobile:mobile.trim()});
    if(error)ctx.notify(error.message,"error");else{ctx.notify("Creditor saved.","success");await ctx.refresh();}
  }

  function bindCreditors() {
    document.querySelector<HTMLInputElement>("#creditorSearch")?.addEventListener("input",e=>{
      const q=(e.currentTarget as HTMLInputElement).value.trim().toLowerCase();
      document.querySelectorAll<HTMLElement>(".creditor-row").forEach(row=>row.style.display=(row.dataset.search||"").includes(q)?"":"none");
    });
    document.querySelector("#addCreditorBtn")?.addEventListener("click",()=>void addCreditor());
    document.querySelectorAll<HTMLButtonElement>(".receive-credit").forEach(b=>b.addEventListener("click",async()=>{
      const supabase=ctx.getSupabase(),id=b.dataset.id;if(!supabase||!id)return;
      const balance=creditorBalance(id);if(balance<=0)return ctx.notify("This creditor has no outstanding balance.","info");
      const amount=Number(prompt("Payment amount. Outstanding: "+ctx.money(balance)));
      if(!Number.isFinite(amount)||amount<=0)return;
      const mode=(prompt("Payment mode: cash, upi, or split","cash")||"cash").toLowerCase();
      let cash=0,upi=0;
      if(mode==="cash")cash=amount;
      else if(mode==="upi")upi=amount;
      else if(mode==="split"){cash=Number(prompt("Cash amount:",String(Math.floor(amount))));upi=amount-cash;}
      else return ctx.notify("Invalid payment mode.","error");
      if(cash<0||upi<0||Math.abs(cash+upi-amount)>0.01)return ctx.notify("Cash + UPI must equal payment amount.","error");
      const {error}=await supabase.rpc("receive_credit_payment",{p_creditor_id:id,p_amount:amount,p_payment_mode:mode,p_cash_amount:cash,p_upi_amount:upi});
      if(error)ctx.notify(error.message,"error");else{ctx.notify("Payment received.","success");await ctx.refresh();}
    }));
    document.querySelectorAll<HTMLButtonElement>(".view-credit-history").forEach(b=>b.addEventListener("click",()=>{
      const id=b.dataset.id;if(!id)return;const cr=ctx.getCreditors().find(x=>x.id===id);
      const rows=ctx.getCreditLedger().filter(x=>x.creditor_id===id).slice(0,100),holder=document.querySelector("#creditorHistoryPanel");if(!holder)return;
      holder.innerHTML=`<div class="modal-card"><div class="section-head"><h3>${ctx.escapeHtml(cr?.name||"Creditor")} — ${ctx.money(creditorBalance(id))} outstanding</h3><button id="closeCreditorHistory" class="ghost">Close</button></div><div class="table-wrap"><table><thead><tr><th>Date</th><th>Type</th><th>Amount</th><th>Mode</th><th>By</th></tr></thead><tbody>${rows.map(x=>`<tr><td>${ctx.formatDateTime(x.created_at)}</td><td>${ctx.escapeHtml(x.type)}</td><td>${ctx.money(Number(x.amount||0))}</td><td>${ctx.escapeHtml(String(x.payment_mode||""))}</td><td>${ctx.escapeHtml(x.profiles?.full_name||"")}</td></tr>`).join("")||'<tr><td colspan="5" class="muted">No history.</td></tr>'}</tbody></table></div></div>`;
      document.querySelector("#closeCreditorHistory")?.addEventListener("click",()=>holder.innerHTML="");
    }));
  }

  function bindCartSteppers() {
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
        b.innerHTML='<span class="ui-icon ui-icon-'+(direction<0?"minus":"plus")+'" aria-hidden="true"></span>';
        let pointerHandled=false;
        b.addEventListener("pointerdown",(event)=>{
          event.preventDefault();
          event.stopPropagation();
          event.stopImmediatePropagation();
          if((event as PointerEvent).button!==0)return;
          pointerHandled=true;
          if(input.readOnly||input.disabled)return;
          const currentText=input.value.trim();
          const parsed=Number(currentText);
          const current=Number.isFinite(parsed)?parsed:0;
          const minRaw=input.getAttribute("min");
          const maxRaw=input.getAttribute("max");
          const minNumber=minRaw===null||minRaw.trim()===""?0:Number(minRaw);
          const maxNumber=maxRaw===null||maxRaw.trim()===""?Infinity:Number(maxRaw);
          const min=Number.isFinite(minNumber)?minNumber:0;
          const max=Number.isFinite(maxNumber)?maxNumber:Infinity;
          let next=current+direction;
          if(next<min)next=min;
          if(next>max)next=max;
          const decimals=(currentText.split(".")[1]||"").length;
          const nextText=decimals?next.toFixed(decimals):String(next);
          input.value=nextText;
          input.defaultValue=nextText;
          input.dispatchEvent(new Event("input",{bubbles:true}));
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
          if(input.readOnly||input.disabled)return;
          const currentText=input.value.trim();
          const parsed=Number(currentText);
          const current=Number.isFinite(parsed)?parsed:0;
          const minRaw=input.getAttribute("min");
          const maxRaw=input.getAttribute("max");
          const minNumber=minRaw===null||minRaw.trim()===""?0:Number(minRaw);
          const maxNumber=maxRaw===null||maxRaw.trim()===""?Infinity:Number(maxRaw);
          const min=Number.isFinite(minNumber)?minNumber:0;
          const max=Number.isFinite(maxNumber)?maxNumber:Infinity;
          let next=current+direction;
          if(next<min)next=min;
          if(next>max)next=max;
          const decimals=(currentText.split(".")[1]||"").length;
          const nextText=decimals?next.toFixed(decimals):String(next);
          input.value=nextText;
          input.defaultValue=nextText;
          input.dispatchEvent(new Event("input",{bubbles:true}));
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
        },true);
        return b;
      };
      wrap.insertBefore(make(-1),input);
      wrap.appendChild(make(1));
    });
  }

  function bindCart() {
    bindCartSteppers();
    const supabase=ctx.getSupabase(),profile=ctx.getProfile(),settings=ctx.getSettings();
    const form=document.querySelector<HTMLFormElement>("#cartAddForm");
    if(form&&supabase&&profile) {
      const select=form.elements.namedItem("product_id") as HTMLSelectElement,search=document.querySelector<HTMLInputElement>("#cartProductSearch");
      const qty=form.elements.namedItem("quantity") as HTMLInputElement,unit=form.elements.namedItem("sold_unit") as HTMLSelectElement,price=form.elements.namedItem("price") as HTMLInputElement;
      const update=()=>{const p=product(select.value);if(!p)return;unit.innerHTML=p.unit_type==="piece"?'<option value="piece">pieces</option>':'<option value="grams">grams</option><option value="kg">kg</option>';unit.value=p.unit_type==="piece"?"piece":"grams";qty.min="0";qty.step="any";price.value=String(Number(p.selling_price_per_base_unit));price.readOnly=profile.role==="worker"&&settings.workers_can_modify_selling_price!==true;};
      search?.addEventListener("input",()=>{const q=search.value.trim().toLowerCase();[...select.options].forEach(o=>o.hidden=!o.textContent!.toLowerCase().includes(q));});
      select.addEventListener("change",update);update();
      form.addEventListener("submit",e=>{e.preventDefault();const p=product(select.value);if(!p)return;const display=Number(qty.value),soldUnit=String(unit.value),base=p.unit_type==="piece"?display:soldUnit==="kg"?display*1000:display,sell=Number(price.value);if(!Number.isFinite(display)||display<=0||base>Number(p.current_stock_base))return ctx.notify("Invalid quantity or insufficient stock.","error");if(p.unit_type==="piece"&&!Number.isInteger(display))return ctx.notify("Piece products must be whole numbers.","error");if(!Number.isFinite(sell)||sell<0)return ctx.notify("Enter a valid selling price.","error");if(profile.role==="worker"&&settings.workers_can_modify_selling_price!==true&&Math.abs(sell-Number(p.selling_price_per_base_unit))>0.000001)return ctx.notify("Workers are not allowed to modify the selling price.","error");if(cartItems.some(x=>x.product_id===p.id))return ctx.notify("This product is already in the cart. Edit the existing row instead.","info");cartItems.push({product_id:p.id,quantity_base:base,quantity_display:display,sold_unit:soldUnit,selling_price_per_base_unit:sell});ctx.renderDashboard();(document.querySelector('[data-tab="cart"]') as HTMLElement | null)?.click();});
    }
    document.querySelector("#cartDoneBtn")?.addEventListener("click",()=>{if(!cartItems.length)return ctx.notify("Add at least one product to the cart.","error");cartStage="preview";ctx.renderDashboard();(document.querySelector('[data-tab="cart"]') as HTMLElement | null)?.click();});
    document.querySelector("#editCartBtn")?.addEventListener("click",()=>{cartStage="edit";ctx.renderDashboard();(document.querySelector('[data-tab="cart"]') as HTMLElement | null)?.click();});
    document.querySelectorAll<HTMLButtonElement>(".delete-cart").forEach(b=>b.addEventListener("click",()=>{cartItems.splice(Number(b.dataset.index),1);ctx.renderDashboard();(document.querySelector('[data-tab="cart"]') as HTMLElement | null)?.click();}));
    document.querySelectorAll<HTMLButtonElement>(".edit-cart").forEach(b=>b.addEventListener("click",()=>{const i=Number(b.dataset.index),item=cartItems[i],p=product(item.product_id);if(!p)return;const q=Number(prompt("Quantity:",String(item.quantity_display)));if(!Number.isFinite(q)||q<=0)return;const u=p.unit_type==="piece"?"piece":(prompt("Unit (grams/kg):",item.sold_unit)||item.sold_unit).toLowerCase();const base=p.unit_type==="piece"?q:u==="kg"?q*1000:q;let sell=item.selling_price_per_base_unit;if(profile?.role==="owner"||settings.workers_can_modify_selling_price===true){const entered=prompt("Selling price per piece/kg:",String(sell));if(entered!==null)sell=Number(entered);}if(!Number.isFinite(sell)||sell<0||base>Number(p.current_stock_base))return ctx.notify("Invalid quantity, price or insufficient stock.","error");cartItems[i]={...item,quantity_base:base,quantity_display:q,sold_unit:u,selling_price_per_base_unit:sell};ctx.renderDashboard();(document.querySelector('[data-tab="cart"]') as HTMLElement | null)?.click();}));
    const pay=document.querySelector<HTMLFormElement>("#cartPaymentForm");
    if(pay&&supabase&&profile) {
      const mode=pay.elements.namedItem("payment_mode") as HTMLSelectElement,cash=pay.elements.namedItem("cash_amount") as HTMLInputElement,upi=pay.elements.namedItem("upi_amount") as HTMLInputElement,credit=pay.elements.namedItem("credit_amount") as HTMLInputElement;
      const refreshPay=()=>{const split=mode.value==="split",isCredit=mode.value==="credit"||mode.value==="credit_split",creditSplit=mode.value==="credit_split";document.querySelector("#cartCashWrap")?.classList.toggle("hidden",!split&&!creditSplit);document.querySelector("#cartUpiWrap")?.classList.toggle("hidden",!split&&!creditSplit);document.querySelector("#cartCreditWrap")?.classList.toggle("hidden",!creditSplit);document.querySelector("#cartCreditorWrap")?.classList.toggle("hidden",!isCredit);if(!split&&!creditSplit){cash.value=mode.value==="cash"?cartTotal().toFixed(2):"0";upi.value=mode.value==="upi"?cartTotal().toFixed(2):"0";credit.value="0";}};
      mode.addEventListener("change",refreshPay);refreshPay();
      document.querySelector("#newCartCreditorBtn")?.addEventListener("click",async()=>{const name=prompt("Creditor name:"),mobile=prompt("Mobile number:");if(!name?.trim()||!mobile?.trim())return;const {error}=await supabase!.rpc("get_or_create_creditor",{p_name:name.trim(),p_mobile:mobile.trim()});if(error)ctx.notify(error.message,"error");else{ctx.notify("Creditor added.","success");await ctx.refresh();}});
      pay.addEventListener("submit",async e=>{e.preventDefault();const creditor=pay.elements.namedItem("creditor_id") as HTMLSelectElement;let c=Number(cash.value),u=Number(upi.value),cr=Number(credit.value);if(mode.value==="cash"){c=cartTotal();u=0;cr=0;}if(mode.value==="upi"){c=0;u=cartTotal();cr=0;}if(mode.value==="credit"){c=0;u=0;cr=cartTotal();}if(mode.value==="split"&&(c<0||u<0||Math.abs(c+u-cartTotal())>0.01))return ctx.notify("Cash + UPI must equal the total.","error");if(mode.value==="credit_split"&&(c<0||u<0||cr<=0||Math.abs(c+u+cr-cartTotal())>0.01))return ctx.notify("Cash + UPI + Credit must equal the total.","error");if((mode.value==="credit"||mode.value==="credit_split")&&!creditor.value)return ctx.notify("Select a creditor.","error");const {error}=await supabase!.rpc("complete_cart_sale",{p_worker_id:profile.id,p_items:cartItems,p_payment_mode:mode.value,p_cash_amount:c,p_upi_amount:u,p_credit_amount:cr,p_creditor_id:(mode.value==="credit"||mode.value==="credit_split")?creditor.value:null});if(error)return ctx.notify(error.message,"error");ctx.notify("Sale confirmed.","success");cartItems=[];cartStage="edit";await ctx.refresh();(document.querySelector('[data-tab="sale"]') as HTMLElement | null)?.click();});
    }
  }

  return { renderCartPanel, renderCreditorsPanel, renderDailySummaryPanel, bindCart, bindCreditors, downloadDailySummary };
}
