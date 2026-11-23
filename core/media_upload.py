"""
Zero-dependency streaming multipart/form-data & media upload helper.

Supports large video/audio uploads from iPhone, iPad, Mac, and Web browsers
without relying on the removed stdlib `cgi` module.
"""

from datetime import datetime
import mimetypes
import os
import re
from typing import Any, BinaryIO, Dict, Optional, Tuple
import uuid


MAX_UPLOAD_BYTES = 500 * 1024 * 1024  # 500 MB (handles iPhone/iPad 4K clips)
MAX_PREAMBLE_BYTES = 64 * 1024
MAX_PART_HEADER_BYTES = 16 * 1024
MAX_MULTIPART_PARTS = 32
MAX_FIELD_TEXT_BYTES = 256 * 1024

ALLOWED_MEDIA_EXTENSIONS = {
    ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".3gp",
    ".m4a", ".wav", ".mp3", ".aac", ".caf", ".ogg", ".oga", ".flac", ".opus", ".aif", ".aiff",
}

CONTENT_TYPE_TO_EXT = {
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/x-m4v": ".m4v",
    "video/webm": ".webm",
    "audio/mp4": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/mpeg": ".mp3",
    "audio/aac": ".aac",
    "audio/webm": ".webm",
    "audio/ogg": ".ogg",
    "audio/flac": ".flac",
}


def sanitize_upload_filename(filename: str, content_type: str = "") -> str:
    base = os.path.basename((filename or "").strip())
    stem, ext = os.path.splitext(base)
    ext = ext.lower()
    if ext not in ALLOWED_MEDIA_EXTENSIONS:
        ext = CONTENT_TYPE_TO_EXT.get((content_type or "").split(";")[0].strip().lower(), "")
    if ext not in ALLOWED_MEDIA_EXTENSIONS:
        ext = ".mp4"
    clean_stem = re.sub(r"[^A-Za-z0-9._\-\u4e00-\u9fff]+", "_", stem).strip("._-") or "media"
    clean_stem = clean_stem[:48]
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return f"{stamp}_{uuid.uuid4().hex[:6]}_{clean_stem}{ext}"


def guess_media_mime(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    overrides = {
        ".mp4": "video/mp4",
        ".mov": "video/quicktime",
        ".m4v": "video/x-m4v",
        ".webm": "video/webm",
        ".m4a": "audio/mp4",
        ".wav": "audio/wav",
        ".mp3": "audio/mpeg",
        ".aac": "audio/aac",
        ".ogg": "audio/ogg",
        ".flac": "audio/flac",
        ".caf": "audio/x-caf",
    }
    if ext in overrides:
        return overrides[ext]
    guessed, _ = mimetypes.guess_type(path)
    return guessed or "application/octet-stream"


def _extract_boundary(content_type: str) -> Optional[bytes]:
    m = re.search(r'boundary=(?:"([^"]+)"|([^;\s]+))', content_type or "", flags=re.IGNORECASE)
    if not m:
        return None
    raw = (m.group(1) or m.group(2) or "").strip()
    if not raw or len(raw) > 200 or not re.fullmatch(r"[A-Za-z0-9'()+_,./:=?-]+", raw):
        return None
    try:
        return raw.encode("ascii")
    except UnicodeEncodeError:
        return None


def _parse_content_disposition(header_val: str) -> Tuple[str, Optional[str]]:
    name_m = re.search(r'name="([^"]+)"', header_val)
    file_m = re.search(r'filename="([^"]*)"', header_val)
    return (name_m.group(1) if name_m else ""), (file_m.group(1) if file_m else None)


def parse_multipart_upload(
    rfile: BinaryIO,
    content_type: str,
    content_length: int,
    upload_dir: str,
    max_bytes: int = MAX_UPLOAD_BYTES,
) -> Tuple[Dict[str, str], Optional[Dict[str, Any]]]:
    """
    Stream-parse a `multipart/form-data` request body, writing the uploaded file directly
    to `upload_dir` without holding the entire file in memory.
    Returns `(fields_dict, file_info_or_none)`.
    """
    if content_length <= 0 or content_length > max_bytes:
        raise ValueError(f"上传体积超出限制 (0 < size <= {max_bytes // (1024 * 1024)} MB)")
    boundary = _extract_boundary(content_type)
    if not boundary:
        raise ValueError("Missing or invalid multipart boundary in Content-Type")

    real_upload_dir = os.path.realpath(upload_dir)
    os.makedirs(real_upload_dir, mode=0o700, exist_ok=True)
    delimiter = b"--" + boundary
    delim_crlf = b"\r\n" + delimiter
    fields: Dict[str, str] = {}
    saved_file: Optional[Dict[str, Any]] = None
    part_count = 0

    remaining = content_length
    buf = bytearray()
    chunk_size = 64 * 1024

    def read_more() -> bool:
        nonlocal remaining
        if remaining <= 0:
            return False
        chunk = rfile.read(min(chunk_size, remaining))
        if not chunk:
            remaining = 0
            return False
        remaining -= len(chunk)
        buf.extend(chunk)
        return True

    def cleanup_saved_file() -> None:
        if saved_file and saved_file.get("path"):
            try:
                os.remove(saved_file["path"])
            except OSError:
                pass

    try:
        # Seek initial boundary with bounded preamble to prevent memory exhaustion
        while True:
            idx = buf.find(delimiter)
            if idx != -1:
                del buf[: idx + len(delimiter)]
                break
            if len(buf) > MAX_PREAMBLE_BYTES + len(delimiter):
                raise ValueError("Invalid multipart payload: preamble exceeds maximum size")
            if not read_more():
                raise ValueError("Invalid multipart payload: opening boundary not found")

        while True:
            while len(buf) < 2 and read_more():
                pass
            if buf[:2] == b"--":
                break
            if buf[:2] == b"\r\n":
                del buf[:2]
            elif buf[:1] == b"\n":
                del buf[:1]

            part_count += 1
            if part_count > MAX_MULTIPART_PARTS:
                raise ValueError("Multipart form contains too many parts")

            # Read part headers up to \r\n\r\n with strict header size limit
            while True:
                hdr_end = buf.find(b"\r\n\r\n")
                if hdr_end != -1:
                    if hdr_end > MAX_PART_HEADER_BYTES:
                        raise ValueError("Multipart part headers exceed maximum size")
                    raw_headers = bytes(buf[:hdr_end]).decode("utf-8", errors="replace")
                    del buf[: hdr_end + 4]
                    break
                if len(buf) > MAX_PART_HEADER_BYTES + 4:
                    raise ValueError("Multipart part headers exceed maximum size")
                if not read_more():
                    return fields, saved_file

            headers: Dict[str, str] = {}
            for line in raw_headers.split("\r\n"):
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()

            field_name, orig_filename = _parse_content_disposition(headers.get("content-disposition", ""))
            part_ct = headers.get("content-type", "")

            is_file_part = orig_filename is not None and orig_filename != ""
            out_fp = None
            target_path = ""
            written = 0
            text_chunks = bytearray()

            if is_file_part:
                if saved_file is not None:
                    raise ValueError("Only one media file may be uploaded per request")
                safe_name = sanitize_upload_filename(orig_filename, part_ct)
                target_path = os.path.realpath(os.path.join(real_upload_dir, safe_name))
                if not target_path.startswith(real_upload_dir + os.sep):
                    raise ValueError("Invalid upload destination path")
                fd = os.open(target_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                out_fp = os.fdopen(fd, "wb")

            try:
                keep_tail = len(delim_crlf) + 4
                while True:
                    idx = buf.find(delim_crlf)
                    if idx != -1:
                        piece = bytes(buf[:idx])
                        del buf[: idx + len(delim_crlf)]
                        if out_fp is not None:
                            out_fp.write(piece)
                            written += len(piece)
                        elif field_name and len(text_chunks) < MAX_FIELD_TEXT_BYTES:
                            text_chunks.extend(piece[: MAX_FIELD_TEXT_BYTES - len(text_chunks)])
                        break

                    # Flush safe prefix to disk / buffer
                    if len(buf) > keep_tail:
                        flush_len = len(buf) - keep_tail
                        piece = bytes(buf[:flush_len])
                        del buf[:flush_len]
                        if out_fp is not None:
                            out_fp.write(piece)
                            written += len(piece)
                        elif field_name and len(text_chunks) < MAX_FIELD_TEXT_BYTES:
                            text_chunks.extend(piece[: MAX_FIELD_TEXT_BYTES - len(text_chunks)])

                    if not read_more():
                        # EOF before closing boundary
                        if buf:
                            piece = bytes(buf)
                            buf.clear()
                            if out_fp is not None:
                                out_fp.write(piece)
                                written += len(piece)
                            elif field_name and len(text_chunks) < MAX_FIELD_TEXT_BYTES:
                                text_chunks.extend(piece[: MAX_FIELD_TEXT_BYTES - len(text_chunks)])
                        break
            except Exception:
                if out_fp is not None:
                    out_fp.close()
                    out_fp = None
                if target_path:
                    try:
                        os.remove(target_path)
                    except OSError:
                        pass
                raise
            finally:
                if out_fp is not None:
                    out_fp.close()

            if is_file_part:
                if written > 0:
                    saved_file = {
                        "field_name": field_name,
                        "original_filename": os.path.basename(orig_filename or ""),
                        "saved_filename": os.path.basename(target_path),
                        "path": target_path,
                        "size_bytes": written,
                        "content_type": part_ct or guess_media_mime(target_path),
                    }
                else:
                    try:
                        os.remove(target_path)
                    except OSError:
                        pass
            elif field_name:
                fields[field_name] = text_chunks.decode("utf-8", errors="replace")
    except Exception:
        cleanup_saved_file()
        raise

    return fields, saved_file
