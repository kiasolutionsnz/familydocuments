(function attachFamilyPassportOcr(global){
  "use strict";
  const baseUrl="http://127.0.0.1:55323";
  const allowed=new Set(["application/pdf","image/jpeg","image/png"]);
  function bytesToBase64(bytes){let value="";const chunk=0x8000;for(let i=0;i<bytes.length;i+=chunk)value+=String.fromCharCode(...bytes.subarray(i,i+chunk));return btoa(value)}
  async function process(file){
    if(!allowed.has(file.type))throw new Error("Choose a PDF, JPEG or PNG file.");
    if(file.size<1||file.size>15*1024*1024)throw new Error("Choose a file smaller than 15 MB.");
    const token=global.familyPassportAuth.getAccessToken();if(!token)throw new Error("Sign in again before processing a document.");
    const bytes=new Uint8Array(await file.arrayBuffer());const digest=await crypto.subtle.digest("SHA-256",bytes);const sha256=[...new Uint8Array(digest)].map(x=>x.toString(16).padStart(2,"0")).join("");
    const response=await fetch(`${baseUrl}/ocr`,{method:"POST",headers:{authorization:`Bearer ${token}`,"content-type":"application/json"},body:JSON.stringify({mime_type:file.type,sha256,content_base64:bytesToBase64(bytes)})});
    const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.error==="no_text_detected"?"No readable text was found.":"OCR could not process this file.");
    return {...body,file_name:file.name};
  }
  global.familyPassportOcr=Object.freeze({baseUrl,process});
})(window);
