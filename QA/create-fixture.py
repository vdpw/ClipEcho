#!/usr/bin/env python3
"""Create two independent v4 databases from synthetic data only; never open user history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import time
import uuid
import zlib

TEXT = "public.utf8-plain-text"
SOURCE = "org.nspasteboard.source"
REMOTE = "com.apple.is-remote-clipboard"


def encoded(items):
    body = bytearray(b"CSB1" + struct.pack("<I", len(items)))
    for flavors in items:
        body += struct.pack("<I", len(flavors))
        for kind, data in flavors:
            kind = kind.encode("utf-8")
            body += struct.pack("<I", len(kind)) + kind + struct.pack("<Q", len(data)) + data
    return bytes(body)


def bounded(data, limit=512):
    if len(data) <= limit:
        return data, False
    end = limit - 3
    while end and data[end] & 0xc0 == 0x80:
        end -= 1
    return data[:end] + b"...", True


def png(width=96, height=64):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    pixels = b"".join(b"\0" + b"".join(bytes((x * 255 // width, y * 255 // height, 150, 255)) for x in range(width)) for y in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


SCHEMA = """
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
CREATE TABLE clipboard_events (
 content_hash TEXT PRIMARY KEY, event_data BLOB NOT NULL, data_type TEXT NOT NULL,
 display BLOB NOT NULL, summary_display BLOB NOT NULL, summary_truncated INTEGER NOT NULL,
 compact_content_hash TEXT, compact_display BLOB, source_bundle_id TEXT,
 is_remote_clipboard INTEGER NOT NULL, byte_count INTEGER NOT NULL, timestamp INTEGER NOT NULL,
 metadata_version INTEGER NOT NULL, is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0,1)));
CREATE INDEX idx_clipboard_events_pinned ON clipboard_events(is_pinned DESC,timestamp DESC,content_hash ASC);
CREATE INDEX idx_clipboard_events_timestamp ON clipboard_events(timestamp DESC,content_hash ASC);
CREATE INDEX idx_clipboard_events_compact ON clipboard_events(compact_content_hash,timestamp DESC,content_hash ASC) WHERE compact_content_hash IS NOT NULL;
CREATE VIRTUAL TABLE clipboard_event_search USING fts5(content_hash UNINDEXED,search_text,compact_search_text,tokenize='trigram');
CREATE TRIGGER clipboard_events_search_after_delete AFTER DELETE ON clipboard_events BEGIN
 DELETE FROM clipboard_event_search WHERE content_hash=OLD.content_hash; END;
CREATE TRIGGER clipboard_events_search_after_update AFTER UPDATE OF content_hash,data_type,display,compact_display ON clipboard_events BEGIN
 DELETE FROM clipboard_event_search WHERE content_hash=OLD.content_hash; END;
PRAGMA user_version=4;
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--filler-items", type=int, default=64)
    options = parser.parse_args()
    if not 0 <= options.filler_items <= 80:
        parser.error("--filler-items must be 0..80")
    root = options.directory or Path("/private/tmp") / ("clipecho-ui-qa-" + uuid.uuid4().hex)
    if not root.is_absolute() or root.exists():
        parser.error("The fixture directory must be a new absolute path")
    root.mkdir(mode=0o700, parents=True)
    assets = root / "assets"
    assets.mkdir(mode=0o700)
    (assets / "项目说明.txt").write_text("This file is synthetic ClipEcho QA data.\n", encoding="utf-8")
    (assets / "Design Folder").mkdir(mode=0o700)
    image = png()
    (assets / "synthetic-gradient.png").write_bytes(image)
    source = "com.clipecho.qa.synthetic"
    rows = []
    epoch = int(time.time() * 1000) - 120_000

    def add(label, items, kind, display, identity, *, compact=None, pin=False, remote=False):
        flavors = list(items[0]) + [(SOURCE, source.encode())]
        if remote:
            flavors += [(REMOTE, b"")]
        items = [flavors] + items[1:]
        blob = encoded(items)
        content_hash = hashlib.sha256(identity).hexdigest()
        compact_hash = hashlib.sha256(compact).hexdigest() if compact is not None else None
        if kind == "png":
            summary, truncated = b"PNG", True
        else:
            summary, truncated = bounded(display)
        byte_count = len(blob) + len(display) + len(summary) + len(compact or b"") + len(source.encode())
        files = json.loads(display) if kind in ("file", "folder", "files", "folders", "files and folders") else None
        search = "\n".join(x["name"] for x in files["items"]) if files else display.decode("utf-8", errors="replace").replace("\0", "") if kind in ("text", "rtf", "html", "video") else ""
        values = (content_hash, blob, kind, display, summary, int(truncated), compact_hash, compact, source, int(remote), byte_count, epoch + len(rows) * 1000, 1, int(pin))
        rows.append({"label": label, "values": values, "search": search,
                     "event": {"items": [{"data_list": [{"type": t, "data": list(b)} for t, b in flavors]} for flavors in items]}})

    def text(label, value, **flags):
        data = value.encode()
        add(label, [[(TEXT, data)]], "text", data, data, compact=data, **flags)

    for index in range(options.filler_items):
        text("paging-" + str(index + 1), f"Synthetic paging item {index + 1:02d} · 合成分页记录，用于保持加载深度与滚动锚点。")
    text("pinned-short", "固定的一条简短文本", pin=True)
    rich_text = "固定的格式化内容\n第二行保留原有换行"
    rich_body = b"{\\rtf1\\ansi Synthetic pinned rich text\\par Second line}"
    add("pinned-rtf", [[("public.rtf", rich_body), (TEXT, rich_text.encode())]], "rtf", "固定的格式化内容 第二行保留原有换行".encode(), rich_body, compact=rich_text.encode(), pin=True)
    text("short-no-hover", "Short complete text")
    text("multiline-code", "func greet(name: String) -> String {\n    // Synthetic clipboard preview\n    return \"Hello, \\(name)\"\n}")
    html_text = "标题与加粗文本\n这是格式化内容的安全合成示例。"
    html_body = "<h2>标题与<strong>加粗文本</strong></h2><p>这是格式化内容的安全合成示例。</p><ul><li>第一项</li><li>第二项</li></ul>".encode()
    add("html-formatting", [[("public.html", html_body), (TEXT, html_text.encode())]], "html", "标题与加粗文本 这是格式化内容的安全合成示例。".encode(), html_body, compact=html_text.encode())
    add("png-gradient", [[("public.png", image)]], "png", image, image)
    file_path = assets / "项目说明.txt"
    file_url = file_path.as_uri().encode()
    display = json.dumps({"format": "copy_stack.file-items.v1", "items": [{"type": "file", "name": file_path.name}]}, ensure_ascii=False, separators=(",", ":")).encode()
    add("single-file", [[("public.file-url", file_url), (TEXT, file_path.name.encode())]], "file", display, file_url)
    folder = assets / "Design Folder"
    folder_url = (folder.as_uri() + "/").encode()
    display = json.dumps({"format": "copy_stack.file-items.v1", "items": [{"type": "file", "name": file_path.name}, {"type": "folder", "name": folder.name}]}, ensure_ascii=False, separators=(",", ":")).encode()
    add("files-and-folder", [[("public.file-url", file_url), (TEXT, (file_path.name + "\r" + folder.name).encode())], [("public.file-url", folder_url)]], "files and folders", display, file_url + folder_url)
    text("remote-text", "来自另一设备的合成文本 · Universal Clipboard", remote=True)
    text("long-hover", "\n".join(f"Synthetic preview line {index:02d} — 保留行距与换行；超出高度后显示省略号。" for index in range(1, 101)))
    text("cjk-40-columns", "复制历史文件夹名称非常非常非常长而且还要继续显示，用于核对四十显示列截断。")

    original = root / "original"
    native = root / "native"
    original.mkdir(mode=0o700); native.mkdir(mode=0o700)
    database = original / "clipecho.db"
    connection = sqlite3.connect(database)
    connection.executescript(SCHEMA)
    settings = {"max_items": "100", "max_history_bytes": "268435456", "max_event_bytes": "33554432", "show_in_menu_bar": "true", "menu_bar_item_limit": "12", "move_restored_item_to_top": "false", "compact_mode": "false", "language": "zh-CN", "theme": "light"}
    connection.executemany("INSERT INTO settings VALUES (?,?)", settings.items())
    connection.executemany("INSERT INTO app_metadata VALUES (?,?)", [("classifier_metadata_version", 1), ("search_index_version", 1)])
    for row in rows:
        connection.execute("INSERT INTO clipboard_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", row["values"])
        compact = row["values"][7]
        connection.execute("INSERT INTO clipboard_event_search VALUES (?,?,?)", (row["values"][0], row["search"], (compact or b"").decode("utf-8")))
    connection.commit(); connection.close(); os.chmod(database, 0o600)
    shutil.copy2(database, native / "clipecho.db")
    manifest = {"synthetic_only": True, "root": str(root), "original_database": str(database), "native_database": str(native / "clipecho.db"), "rows": [{"label": row["label"], "content_hash": row["values"][0], "data_type": row["values"][2], "is_pinned": bool(row["values"][-1]), "event": row["event"]} for row in rows]}
    (root / "fixture.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(root / "fixture.json", 0o600)
    print(json.dumps({key: manifest[key] for key in ["root", "original_database", "native_database"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
