#!/usr/bin/env python3
"""A tiny stand-in for the Telegram Bot API, for Automate's --telegramtest. Listens on 127.0.0.1 only.

  POST /control/push   {"update": {...}}  queue an incoming update (message or callback_query)
  GET  /control/sent                       everything the bot sent, as a JSON list
Bot API: getMe, getUpdates (long poll), sendMessage, answerCallbackQuery, editMessageReplyMarkup, sendChatAction,
setMyCommands, getFile, and /file/bot<token>/<path> downloads.
"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
lock = threading.Condition()
updates, sent, files = [], [], {"doc1": ("docs/secret.txt", b"The secret word is mango.\n")}
next_update, next_message = [1000], [1]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, obj, code=200, raw=None):
        body = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/control/sent":
            with lock: return self.reply(sent)
        if self.path.startswith("/file/"):
            for fid, (path, data) in files.items():
                if self.path.endswith(path): return self.reply(None, raw=data)
            return self.reply({"ok": False}, 404)
        self.reply({"ok": False, "description": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/control/push":
            with lock:
                u = dict(body["update"]); u["update_id"] = next_update[0]; next_update[0] += 1
                updates.append(u); lock.notify_all()
            return self.reply({"ok": True})
        parts = self.path.split("/")
        if len(parts) < 3 or not parts[1].startswith("bot"): return self.reply({"ok": False}, 404)
        if parts[1] != "botTEST:TOKEN": return self.reply({"ok": False, "description": "Unauthorized"}, 401)
        method = parts[2]
        if method == "getMe":
            return self.reply({"ok": True, "result": {"id": 1, "username": "automate_test_bot"}})
        if method == "getUpdates":
            offset, deadline = body.get("offset", 0), time.time() + min(body.get("timeout", 0), 2)
            with lock:
                while True:
                    ready = [u for u in updates if u["update_id"] >= offset]
                    if ready or time.time() >= deadline: break
                    lock.wait(0.2)
            return self.reply({"ok": True, "result": ready})
        if method == "sendMessage":
            if body.get("parse_mode") == "HTML" and "<unclosed" in body.get("text", ""):
                return self.reply({"ok": False, "description": "Bad Request: can't parse entities"}, 400)
            with lock:
                mid = next_message[0]; next_message[0] += 1
                sent.append({"method": method, "id": mid, **body})
            return self.reply({"ok": True, "result": {"message_id": mid}})
        if method == "getFile":
            path = files.get(body.get("file_id"), (None,))[0]
            return self.reply({"ok": True, "result": {"file_path": path}} if path else {"ok": False}, 200 if path else 400)
        with lock: sent.append({"method": method, **body})
        return self.reply({"ok": True, "result": True})

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
