"use client";

import { FormEvent, useRef, useState } from "react";

type ChatMessage = { role: "assistant" | "user"; text: string; source?: { title: string; url: string } };

const API = "https://api-familydocuments.servicehub.co.nz/help/chat";
const prompts = ["How do I add a document?", "How does Google Drive storage work?", "How do family reminders work?"];

export default function HelpChat() {
  const [open, setOpen] = useState(false);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([{role:"assistant",text:"Kia ora! I can help with using Family Documents—documents, storage, email forwarding, reminders, privacy, travel, rentals, and saved links."}]);
  const input = useRef<HTMLInputElement>(null);

  async function ask(event: FormEvent, suggested?: string) {
    event.preventDefault();
    const question = (suggested ?? message).trim().slice(0, 500);
    if (question.length < 2 || busy) return;
    setMessages(current => [...current, {role:"user",text:question}]);
    setMessage("");
    setBusy(true);
    try {
      const response = await fetch(API, {method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({message:question})});
      const data = await response.json() as {answer?:unknown;source?:unknown;error?:unknown};
      if (!response.ok || typeof data.answer !== "string") throw new Error(typeof data.error === "string" ? data.error : "help_unavailable");
      const source = data.source && typeof data.source === "object" && "title" in data.source && "url" in data.source && typeof data.source.title === "string" && typeof data.source.url === "string" && data.source.url.startsWith("/faq") ? {title:data.source.title,url:data.source.url} : undefined;
      setMessages(current => [...current, {role:"assistant",text:data.answer!.slice(0, 1200),source}]);
    } catch {
      setMessages(current => [...current, {role:"assistant",text:"I can’t reach the help service just now. The FAQ is still available, or email support@familydocuments.app if you’re stuck.",source:{title:"Open the FAQ",url:"/faq"}}]);
    } finally {
      setBusy(false);
      requestAnimationFrame(() => input.current?.focus());
    }
  }

  return <>
    <button className="chat-launcher" type="button" aria-expanded={open} aria-controls="help-chat" onClick={() => {setOpen(value=>!value);requestAnimationFrame(()=>input.current?.focus())}}><span aria-hidden="true">?</span> Ask us</button>
    {open && <aside className="help-chat" id="help-chat" aria-label="Family Documents help assistant">
      <header><div><strong>Ask Family Documents</strong><small>Product help only</small></div><button type="button" aria-label="Close help" onClick={()=>setOpen(false)}>×</button></header>
      <div className="chat-notice">No access to your account or documents. This chat is kept only in this open page.</div>
      <div className="chat-messages" aria-live="polite">
        {messages.map((item,index)=><div className={`chat-message ${item.role}`} key={`${item.role}-${index}`}><p>{item.text}</p>{item.source&&<a href={item.source.url}>{item.source.title} →</a>}</div>)}
        {busy&&<div className="chat-message assistant"><p>Checking the Family Documents help guide…</p></div>}
      </div>
      {messages.length===1&&<div className="chat-prompts">{prompts.map(prompt=><button key={prompt} type="button" onClick={event=>ask(event,prompt)}>{prompt}</button>)}</div>}
      <form onSubmit={ask}><label htmlFor="help-question">Ask about the app</label><div><input ref={input} id="help-question" value={message} onChange={event=>setMessage(event.target.value)} maxLength={500} autoComplete="off" placeholder="How do I forward an email?"/><button type="submit" disabled={busy||message.trim().length<2}>Send</button></div></form>
      <p className="chat-scope">For app guidance only—not medical, legal, financial, tax, or emergency advice.</p>
    </aside>}
  </>;
}
