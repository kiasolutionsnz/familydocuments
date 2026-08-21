import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from paddleocr import PaddleOCR

HOST="0.0.0.0"
PORT=8080
ORIGIN="http://127.0.0.1:3300"
SECRET=os.environ["GOTRUE_JWT_SECRET"].encode()
MAX_BYTES=15*1024*1024
MIMES={"application/pdf":".pdf","image/jpeg":".jpg","image/png":".png"}
MODELS=Path("/opt/fpocr/models")

def b64url(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value)%4))

def verify_jwt(header):
    if not header.startswith("Bearer "): raise ValueError("missing_token")
    token=header[7:]
    parts=token.split(".")
    if len(parts)!=3: raise ValueError("malformed_token")
    protected=json.loads(b64url(parts[0])); claims=json.loads(b64url(parts[1]))
    if protected.get("alg")!="HS256": raise ValueError("invalid_algorithm")
    expected=hmac.new(SECRET,f"{parts[0]}.{parts[1]}".encode(),hashlib.sha256).digest()
    if not hmac.compare_digest(expected,b64url(parts[2])): raise ValueError("invalid_signature")
    if claims.get("aud")!="authenticated" or claims.get("role")!="authenticated": raise ValueError("invalid_audience")
    if not isinstance(claims.get("sub"),str) or float(claims.get("exp",0))<=time.time(): raise ValueError("expired_token")
    return claims

def engine():
    return PaddleOCR(
      doc_orientation_classify_model_name="PP-LCNet_x1_0_doc_ori",doc_orientation_classify_model_dir=str(MODELS/"PP-LCNet_x1_0_doc_ori_infer"),
      text_detection_model_name="PP-OCRv5_mobile_det",text_detection_model_dir=str(MODELS/"PP-OCRv5_mobile_det_infer"),
      text_recognition_model_name="en_PP-OCRv5_mobile_rec",text_recognition_model_dir=str(MODELS/"en_PP-OCRv5_mobile_rec_infer"),
      use_doc_orientation_classify=True,use_doc_unwarping=False,use_textline_orientation=False,enable_mkldnn=False,cpu_threads=4)

OCR=engine()

class Handler(BaseHTTPRequestHandler):
    server_version="FamilyPassportOCR/0.1"
    def log_message(self,fmt,*args): print(json.dumps({"event":"http","message":fmt%args}),flush=True)
    def cors(self):
        self.send_header("Access-Control-Allow-Origin",ORIGIN)
        self.send_header("Vary","Origin")
        self.send_header("Access-Control-Allow-Headers","authorization,content-type")
        self.send_header("Access-Control-Allow-Methods","POST,OPTIONS,GET")
    def reply(self,status,payload):
        raw=json.dumps(payload,separators=(",",":")).encode()
        self.send_response(status);self.cors();self.send_header("Content-Type","application/json");self.send_header("Content-Length",str(len(raw)));self.send_header("Cache-Control","no-store");self.end_headers();self.wfile.write(raw)
    def do_OPTIONS(self):
        if self.headers.get("Origin")!=ORIGIN: return self.reply(403,{"error":"origin_denied"})
        self.reply(200,{"ok":True})
    def do_GET(self):
        if self.path=="/health": return self.reply(200,{"status":"ok","engine":"paddleocr-3.4.0-ppocrv5-mobile"})
        self.reply(404,{"error":"not_found"})
    def do_POST(self):
        if self.path!="/ocr": return self.reply(404,{"error":"not_found"})
        if self.headers.get("Origin")!=ORIGIN: return self.reply(403,{"error":"origin_denied"})
        try: claims=verify_jwt(self.headers.get("Authorization", ""))
        except Exception: return self.reply(401,{"error":"authentication_required"})
        try:
            length=int(self.headers.get("Content-Length","0"))
            if length<1 or length>MAX_BYTES*2: raise ValueError("request_size_limit")
            payload=json.loads(self.rfile.read(length))
            mime=payload.get("mime_type"); expected_hash=str(payload.get("sha256","")).lower(); encoded=payload.get("content_base64")
            if mime not in MIMES or not re.fullmatch(r"[0-9a-f]{64}",expected_hash) or not isinstance(encoded,str): raise ValueError("invalid_request")
            data=base64.b64decode(encoded,validate=True)
            if not 1<=len(data)<=MAX_BYTES or hashlib.sha256(data).hexdigest()!=expected_hash: raise ValueError("source_integrity_failed")
            directory=Path(tempfile.mkdtemp(prefix="fpocr-",dir="/tmp"))
            try:
                path=directory/("source"+MIMES[mime]);path.write_bytes(data)
                predictions=[entry.json for entry in OCR.predict(str(path))]
                if not 1<=len(predictions)<=20: raise ValueError("page_limit")
                pages=[];all_scores=[];all_text=[]
                for index,prediction in enumerate(predictions):
                    raw=prediction.get("res",prediction);texts=raw.get("rec_texts");scores=raw.get("rec_scores")
                    if not isinstance(texts,list) or not isinstance(scores,list) or len(texts)!=len(scores): raise ValueError("malformed_engine_output")
                    spans=[]
                    for text,score in zip(texts,scores):
                        if isinstance(text,str) and text.strip() and isinstance(score,(int,float)) and 0<=score<=1:
                            spans.append({"text":text.strip(),"confidence":round(float(score),4)});all_text.append(text.strip());all_scores.append(float(score))
                    pages.append({"page_number":index+1,"spans":spans})
                if not all_text: raise ValueError("no_text_detected")
                self.reply(200,{"engine":"paddleocr-3.4.0-ppocrv5-mobile","source":{"sha256":expected_hash,"mime_type":mime,"byte_length":len(data)},"pages":pages,"text":"\n".join(all_text),"mean_confidence":round(sum(all_scores)/len(all_scores),4),"warnings":["NON_AUTHORITATIVE","CRITICAL_FIELDS_REQUIRE_CONFIRMATION"],"subject":claims["sub"]})
            finally: shutil.rmtree(directory,ignore_errors=True)
        except ValueError as error: self.reply(422,{"error":str(error)[:80]})
        except Exception: self.reply(500,{"error":"ocr_failed"})

ThreadingHTTPServer((HOST,PORT),Handler).serve_forever()
