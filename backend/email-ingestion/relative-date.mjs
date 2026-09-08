const WEEKDAYS=new Map([
  ['sunday',0],['monday',1],['tuesday',2],['wednesday',3],
  ['thursday',4],['friday',5],['saturday',6],
]);
const NUMBERS=new Map([['one',1],['two',2],['three',3],['four',4],['five',5],['six',6],['seven',7],['eight',8],['nine',9],['ten',10],['eleven',11],['twelve',12]]);

function localDateParts(reference,timeZone){
  const parts=new Intl.DateTimeFormat('en-CA',{timeZone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(reference);
  const value=type=>Number(parts.find(x=>x.type===type)?.value);
  return {year:value('year'),month:value('month'),day:value('day')};
}

function addDays(parts,days){
  const value=new Date(Date.UTC(parts.year,parts.month-1,parts.day+days));
  return {year:value.getUTCFullYear(),month:value.getUTCMonth()+1,day:value.getUTCDate()};
}

function iso(parts){return `${parts.year}-${String(parts.month).padStart(2,'0')}-${String(parts.day).padStart(2,'0')}`}

export function resolveRelativeDueDate(text,reference=new Date(),timeZone='Pacific/Auckland'){
  const source=String(text||'').toLowerCase();
  if(!Number.isFinite(reference.getTime()))return null;
  const base=localDateParts(reference,timeZone);
  if(/\btomorrow\b/.test(source))return iso(addDays(base,1));
  if(/\btoday\b/.test(source))return iso(base);
  const interval=source.match(/\bin\s+(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(day|days|week|weeks)\b/);
  if(interval){const count=/^\d+$/.test(interval[1])?Number(interval[1]):NUMBERS.get(interval[1]);return iso(addDays(base,count*(interval[2].startsWith('week')?7:1)))}
  const next=source.match(/\bnext\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/);
  if(next){const baseDay=new Date(Date.UTC(base.year,base.month-1,base.day)).getUTCDay(),target=WEEKDAYS.get(next[1]);return iso(addDays(base,(target-baseDay+7)%7||7))}
  return null;
}

export function resolveRelativeDueTime(text){
  const source=String(text||'').toLowerCase();
  const match=source.match(/\b(?:at\s*)?(\d{1,2})(?::([0-5]\d))?\s*(am|pm)\b/);
  if(match){
    let hour=Number(match[1]);
    if(hour<1||hour>12)return null;
    if(match[3]==='am')hour=hour===12?0:hour;
    else hour=hour===12?12:hour+12;
    return `${String(hour).padStart(2,'0')}:${match[2]||'00'}:00`;
  }
  const twentyFour=source.match(/\b(?:at\s+)([01]?\d|2[0-3]):([0-5]\d)\b/);
  return twentyFour?`${String(Number(twentyFour[1])).padStart(2,'0')}:${twentyFour[2]}:00`:null;
}

export function resolveRelativeDue(text,reference=new Date(),timeZone='Pacific/Auckland'){
  return {date:resolveRelativeDueDate(text,reference,timeZone),time:resolveRelativeDueTime(text),timeZone};
}
