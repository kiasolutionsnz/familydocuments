(function(root,factory){
  const api=factory();
  if(typeof module==="object"&&module.exports)module.exports=api;
  root.FamilyDocumentExtraction=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const months=["january","february","march","april","may","june","july","august","september","october","november","december"];
  const field=(value=null,confidence=0,evidence="")=>({value,confidence,evidence});
  function normaliseDate(raw){
    const text=String(raw||"").trim().toLowerCase().replace(/(\d)(st|nd|rd|th)\b/g,"$1");
    let year,month,day,confidence=.99,match;
    if((match=text.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/))){[,year,month,day]=match;}
    else if((match=text.match(/^(\d{1,2})[ /.-]([a-z]+)[ ,/.-]+(\d{4})$/))){day=match[1];month=months.findIndex(x=>x===match[2]||x.slice(0,3)===match[2])+1;year=match[3];}
    else if((match=text.match(/^([a-z]+) (\d{1,2}),? (\d{4})$/))){month=months.findIndex(x=>x===match[1]||x.slice(0,3)===match[1])+1;day=match[2];year=match[3];}
    else if((match=text.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/))){[,day,month,year]=match;confidence=Number(day)<=12&&Number(month)<=12?.65:.95;}
    else return field();
    year=Number(year);month=Number(month);day=Number(day);
    const date=new Date(Date.UTC(year,month-1,day));
    if(year<1900||year>2199||month<1||month>12||day<1||date.getUTCFullYear()!==year||date.getUTCMonth()+1!==month||date.getUTCDate()!==day)return field();
    return field(`${year}-${String(month).padStart(2,"0")}-${String(day).padStart(2,"0")}`,confidence,String(raw));
  }
  function labelled(lines,pattern){
    const matches=lines.map(line=>({line,match:line.match(pattern)})).filter(x=>x.match&&x.match[1]?.trim());
    if(!matches.length)return field();
    const distinct=new Set(matches.map(x=>x.match[1].trim().toLowerCase()));
    return field(matches[0].match[1].trim(),distinct.size>1?.45:.99,matches.map(x=>x.line).join("\n"));
  }
  function extract(candidate,categories=[]){
    const lines=String(candidate?.text||"").slice(0,100000).split(/\r?\n/).map(x=>x.trim()).filter(Boolean),text=lines.join("\n");
    const titleCase=value=>value===value.toUpperCase()?value.toLowerCase().replace(/\b[a-z]/g,x=>x.toUpperCase()):value;
    let title=labelled(lines,/^(?:document title|title|document name)\s*:\s*(.+)$/i);
    if(!title.value){const heading=lines.slice(0,8).find(x=>x.length>=4&&x.length<=120&&!x.includes(":")&&/\b(policy|insurance|passport|receipt|warranty|invoice|certificate)\b/i.test(x));title=heading?field(titleCase(heading),.95,heading):field(String(candidate?.file_name||"Untitled document").replace(/\.[^.]+$/,""),.3,"");}
    const types=[[/\b(passport)\b/i,"Passport","People"],[/\b(warranty|guarantee)\b/i,"Warranty","Purchases & warranties"],[/\b(insurance|policy|premium)\b/i,"Insurance policy","Insurance"],[/\b(receipt|invoice)\b/i,"Receipt","Purchases & warranties"]];
    const type=types.find(([pattern])=>pattern.test(text)),evidence=type?lines.find(x=>type[0].test(x)):"";
    const documentType=type?field(type[1],.95,evidence):field("Document",.3,"");
    const category=type?field(type[2],.95,evidence):field();
    const categoryId=categories.find(x=>x.name.toLowerCase()===String(category.value).toLowerCase())?.id||null;
    const provider=labelled(lines,/^(?:provider|insurer|insurance company|issued by|issuing authority|retailer|merchant|supplier|store|seller|manufacturer)\s*:\s*(.+)$/i);
    const importantDates=[];
    for(const line of lines){
      const match=line.match(/^((?:(?:policy|insurance|passport|warranty|payment|invoice)\s+)?(?:renewal(?: date)?|renews(?: on)?|expiry(?: date)?|expiration(?: date)?|date of expiry|expires(?: on)?|valid until|due(?: date)?|purchase date|date of purchase|receipt date|invoice date|date))\s*:\s*(.+)$/i);
      if(!match)continue;
      const label=match[1].toLowerCase(),parsed=normaliseDate(match[2]),kind=/renew/.test(label)?"renewal":/expir|valid until/.test(label)?"expiry":/due/.test(label)?"due":"document_date";
      importantDates.push({type:kind,...parsed,evidence:line});
    }
    for(const date of importantDates){if(new Set(importantDates.filter(x=>x.type===date.type&&x.value).map(x=>x.value)).size>1)date.confidence=Math.min(date.confidence,.45);}
    const critical=importantDates.find(x=>x.type==="renewal")||importantDates.find(x=>x.type==="expiry")||importantDates.find(x=>x.type==="due")||field();
    return {title,documentType,category,categoryId,provider,importantDates,criticalDate:critical};
  }
  return {extract,normaliseDate};
});
