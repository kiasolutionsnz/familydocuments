/* eslint-disable @next/next/no-html-link-for-pages */
import type { Metadata } from "next";

export const metadata:Metadata={title:"Family Documents FAQ | Storage, privacy, email and reminders",description:"Answers about Family Documents accounts, Google Drive storage, uploads, OCR, email forwarding, privacy, reminders, travel, rentals, and saved links.",alternates:{canonical:"/faq"}};

const groups=[
  {id:"getting-started",title:"Getting started",items:[
    ["What is Family Documents?","Family Documents is a private family workspace for organising important records, renewal reminders, forwarded emails, travel information, rental property evidence, and useful links."],
    ["Is the trial free?","Yes. Family Documents is free during early access and does not require a credit card. You will not be charged unless you later choose a paid plan."],
    ["How do I start?","Create an account, confirm your email, name your household, and connect a household Google Drive folder. You can then add records manually, upload a photo or PDF, or forward an email."],
  ]},
  {id:"storage",title:"Storage and Google Drive",items:[
    ["Does Family Documents see my whole Google Drive?","No. It uses Google’s limited drive.file permission. The app can access only files it creates or files you explicitly select through Google’s picker."],
    ["Does every family member need access to the Google folder?","No. The household owner connects the storage. Other members use the Family Documents permission system and do not need direct Google folder access."],
    ["Can I use OneDrive?","Not yet. The current release supports Google Drive. Additional storage providers remain planned work."],
  ]},
  {id:"documents",title:"Documents and OCR",items:[
    ["How do I add a document?","Choose Add document, then take a photo, select a PDF, or enter the details manually. The upload is placed in the connected household storage after you confirm it."],
    ["Is OCR required?","No. OCR is optional. You can save a record manually, or use OCR to suggest text and details from a photo or PDF."],
    ["Does AI choose the category automatically?","The app can suggest a category, title, dates, and other details from the filename or extracted text. You review and confirm every suggestion before it becomes a trusted record."],
  ]},
  {id:"email-inbox",title:"Email inbox",items:[
    ["How does email forwarding work?","Forward a bill, booking, or attachment to your private household address. The app security-checks it and places it in a review queue; it does not automatically create a confirmed record or reminder."],
    ["How is spam reduced?","Household owners can allow trusted sender addresses. Unknown senders are quarantined for review rather than treated as trusted records."],
    ["Can I delete an unwanted email?","Yes. Move an email to the recoverable bin from its review or evidence view. Restore it if it was removed by mistake."],
  ]},
  {id:"reminders",title:"Reminders",items:[
    ["Who receives a reminder?","A personal reminder goes only to its creator. It is sent to family members only when you explicitly select them or confirm it as a shared household item."],
    ["Can reminders repeat?","Yes. You can choose one-off, monthly, or yearly reminders after confirming the schedule and next due date."],
  ]},
  {id:"privacy",title:"Privacy and sharing",items:[
    ["Who can see records in the Family Library?","Confirmed Library records are available to active members of your family workspace. Supported personal items and Saved Links can remain private or be shared with named family members."],
    ["Can the website assistant see my documents?","No. The public help assistant has no access to accounts, documents, email, Google Drive, or household data. It answers only from an approved product-help guide."],
    ["Does the help chat retain my conversation?","The open web page keeps the visible conversation only in memory for that page. The help gateway does not save chat history. Do not enter passwords, verification codes, private documents, or secret keys."],
  ]},
  {id:"travel",title:"Travel",items:[["What can I keep with a trip?","Group bookings, tickets, itinerary items, travellers, costs, and supporting documents under one trip. Email suggestions require confirmation before being attached."]]},
  {id:"rentals",title:"Rental properties",items:[["What can I track for a rental property?","Organise bills, invoices, due dates, providers, payment status, and source evidence by property. Exports help preparation for an accountant; Family Documents does not provide tax advice."]]},
  {id:"saved-links",title:"Saved links",items:[["Can I save Reels and bookmarks privately?","Yes. Save useful links into categories. They remain private unless you deliberately share them with selected family members."]]},
  {id:"support",title:"Support",items:[["What should I do when something is not working?","Record the page name and exact error text, then email contact@familydocuments.app. Never send a password, verification code, access token, or secret key."]]},
] as const;

const schema={"@context":"https://schema.org","@type":"FAQPage",mainEntity:groups.flatMap(group=>group.items.map(item=>({"@type":"Question",name:item[0],acceptedAnswer:{"@type":"Answer",text:item[1]}})))};

export default function FAQ(){return <><nav className="site-nav content-nav"><a className="wordmark" href="/"><span>FD</span><b>Family Documents</b></a><div className="nav-links"><a href="/blog">Blog</a><a className="nav-auth nav-sign-in" href="/app/">Sign in</a><a className="button small nav-auth" href="/app/">Register free</a></div></nav><main className="content-page"><script type="application/ld+json" dangerouslySetInnerHTML={{__html:JSON.stringify(schema).replace(/</g,"\\u003c")}}/><section className="content-hero"><p className="eyebrow">Frequently asked questions</p><h1>Clear answers about Family Documents.</h1><p>Find help with setup, storage, documents, OCR, forwarded email, reminders, privacy, travel, rentals, and saved links. Or use “Ask us” for a guided answer from this same approved help content.</p></section><div className="faq-list">{groups.map(group=><section className="faq-group" id={group.id} key={group.id}><h2>{group.title}</h2>{group.items.map(item=><details key={item[0]}><summary>{item[0]}</summary><p>{item[1]}</p></details>)}</section>)}</div></main></>}
