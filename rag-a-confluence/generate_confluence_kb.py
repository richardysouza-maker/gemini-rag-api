"""
Extrator de Knowledge Base do Confluence Cloud.

Percorre um space do Confluence (pages + blog posts) via REST API v2,
converte o body (storage format / XHTML) para Markdown e salva um
JSON com todos os artigos.

Uso:
    python generate_confluence_kb.py
    python generate_confluence_kb.py --skip-blogposts
    python generate_confluence_kb.py --output meu_kb.json

Requer no .env:
    CONFLUENCE_DOMAIN    ex: growmate.atlassian.net
    CONFLUENCE_EMAIL     email da conta Atlassian
    CONFLUENCE_API_TOKEN https://id.atlassian.com/manage-profile/security/api-tokens
    CONFLUENCE_SPACE_ID  id numerico ou key do space (ex: SUPT)
"""

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv
from markdownify import markdownify
from requests.auth import HTTPBasicAuth

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("confluence-kb")

DOMAIN = os.getenv("CONFLUENCE_DOMAIN", "").strip().replace("https://", "").rstrip("/")
EMAIL = os.getenv("CONFLUENCE_EMAIL", "").strip()
API_TOKEN = os.getenv("CONFLUENCE_API_TOKEN", "").strip()
SPACE_REF = os.getenv("CONFLUENCE_SPACE_ID", "").strip()

if not all([DOMAIN, EMAIL, API_TOKEN, SPACE_REF]):
    sys.exit(
        "ERRO: variaveis de ambiente faltando.\n"
        "Preencha CONFLUENCE_DOMAIN, CONFLUENCE_EMAIL, "
        "CONFLUENCE_API_TOKEN e CONFLUENCE_SPACE_ID no .env"
    )

BASE_URL = f"https://{DOMAIN}/wiki"
API_V2 = f"{BASE_URL}/api/v2"
API_V1 = f"{BASE_URL}/rest/api"

session = requests.Session()
session.auth = HTTPBasicAuth(EMAIL, API_TOKEN)
session.headers.update({"Accept": "application/json"})

POLITENESS_SLEEP = 0.3
MAX_BACKOFF = 64


def request_with_retry(method: str, url: str, **kwargs) -> requests.Response:
    """GET/POST com retry exponencial para 429 e 5xx."""
    backoff = 1
    for attempt in range(8):
        resp = session.request(method, url, timeout=30, **kwargs)
        if resp.status_code < 400:
            return resp
        if resp.status_code in (429, 500, 502, 503, 504):
            retry_after = resp.headers.get("Retry-After")
            wait = int(retry_after) if retry_after and retry_after.isdigit() else backoff
            wait = min(wait, MAX_BACKOFF)
            log.warning(
                "HTTP %s em %s — aguardando %ss (tentativa %d/8)",
                resp.status_code, url, wait, attempt + 1,
            )
            time.sleep(wait)
            backoff = min(backoff * 2, MAX_BACKOFF)
            continue
        # erro definitivo
        log.error("HTTP %s em %s: %s", resp.status_code, url, resp.text[:300])
        resp.raise_for_status()
    resp.raise_for_status()
    return resp


def resolve_space(space_ref: str) -> dict[str, str]:
    """
    Aceita tanto space ID numerico quanto space key.
    Retorna {"id": "...", "key": "..."}.
    """
    if space_ref.isdigit():
        resp = request_with_retry("GET", f"{API_V2}/spaces/{space_ref}")
        data = resp.json()
        return {"id": str(data["id"]), "key": data.get("key", "")}

    # trata como key
    resp = request_with_retry("GET", f"{API_V2}/spaces", params={"keys": space_ref})
    results = resp.json().get("results", [])
    if not results:
        sys.exit(f"ERRO: space com key '{space_ref}' nao encontrado.")
    space = results[0]
    return {"id": str(space["id"]), "key": space.get("key", "")}


def fetch_paginated(url: str, params: dict | None = None) -> list[dict]:
    """Segue _links.next ate esgotar a paginacao."""
    all_items: list[dict] = []
    next_url: str | None = url
    next_params = dict(params or {})

    while next_url:
        resp = request_with_retry("GET", next_url, params=next_params)
        payload = resp.json()
        results = payload.get("results", [])
        all_items.extend(results)
        log.info("  ... baixadas %d itens (total acumulado: %d)", len(results), len(all_items))

        next_link = payload.get("_links", {}).get("next")
        if next_link:
            # next ja vem como path absoluto a partir do dominio base
            next_url = f"https://{DOMAIN}{next_link}" if next_link.startswith("/") else next_link
            next_params = None  # ja inclusos no next link
        else:
            next_url = None

        time.sleep(POLITENESS_SLEEP)

    return all_items


def fetch_pages(space_id: str) -> list[dict]:
    log.info("Buscando pages do space %s...", space_id)
    url = f"{API_V2}/spaces/{space_id}/pages"
    params = {
        "body-format": "storage",
        "limit": 250,
        "status": "current",
    }
    return fetch_paginated(url, params)


def fetch_blogposts(space_id: str) -> list[dict]:
    log.info("Buscando blog posts do space %s...", space_id)
    url = f"{API_V2}/spaces/{space_id}/blogposts"
    params = {
        "body-format": "storage",
        "limit": 250,
        "status": "current",
    }
    return fetch_paginated(url, params)


def xhtml_to_markdown(xhtml: str) -> str:
    """Converte storage format (XHTML) para Markdown limpo."""
    if not xhtml:
        return ""
    md = markdownify(
        xhtml,
        heading_style="ATX",       # usa # em vez de ====
        bullets="-",               # listas com hifen
        strip=["script", "style"],
    )
    # remove linhas em branco excessivas (3+ seguidas -> 2)
    lines = md.split("\n")
    clean_lines: list[str] = []
    blank_count = 0
    for line in lines:
        if line.strip() == "":
            blank_count += 1
            if blank_count <= 2:
                clean_lines.append(line)
        else:
            blank_count = 0
            clean_lines.append(line.rstrip())
    return "\n".join(clean_lines).strip()


def normalize_item(item: dict, space: dict[str, str], item_type: str) -> dict[str, Any]:
    """Converte um payload do Confluence v2 no schema do KB."""
    body = (item.get("body") or {}).get("storage") or {}
    xhtml = body.get("value", "") or ""
    md = xhtml_to_markdown(xhtml)

    webui = (item.get("_links") or {}).get("webui", "")
    url = f"{BASE_URL}{webui}" if webui else ""

    version = item.get("version") or {}
    modified_time = version.get("createdAt") or item.get("createdAt")

    return {
        "id": str(item.get("id", "")),
        "title": item.get("title", ""),
        "type": item_type,
        "space_id": space["id"],
        "space_key": space["key"],
        "parent_id": str(item.get("parentId") or "") or None,
        "status": item.get("status", ""),
        "url": url,
        "created_at": item.get("createdAt", ""),
        "modified_time": modified_time or "",
        "version": version.get("number", 1),
        "content": md,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-blogposts",
        action="store_true",
        help="Nao extrair blog posts (apenas pages).",
    )
    parser.add_argument(
        "--output",
        help="Path do JSON de saida. Default: confluence_kb_YYYY-MM-DD.json",
    )
    args = parser.parse_args()

    include_blogposts = not args.skip_blogposts
    env_flag = os.getenv("CONFLUENCE_INCLUDE_BLOGPOSTS", "").lower()
    if env_flag in ("false", "0", "no"):
        include_blogposts = False

    log.info("Resolvendo space '%s'...", SPACE_REF)
    space = resolve_space(SPACE_REF)
    log.info("Space resolvido: id=%s key=%s", space["id"], space["key"])

    pages = fetch_pages(space["id"])
    log.info("Pages encontradas: %d", len(pages))

    blogposts: list[dict] = []
    if include_blogposts:
        try:
            blogposts = fetch_blogposts(space["id"])
            log.info("Blog posts encontrados: %d", len(blogposts))
        except requests.HTTPError as e:
            log.warning("Falha ao buscar blog posts (ignorando): %s", e)

    records: list[dict] = []
    for p in pages:
        records.append(normalize_item(p, space, "page"))
    for b in blogposts:
        records.append(normalize_item(b, space, "blogpost"))

    # estatisticas basicas
    empty = sum(1 for r in records if not r["content"].strip())
    log.info("Total de artigos: %d (vazios: %d)", len(records), empty)

    output = args.output or f"confluence_kb_{datetime.now().strftime('%Y-%m-%d')}.json"
    Path(output).write_text(
        json.dumps(records, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    size_kb = Path(output).stat().st_size / 1024
    log.info("Salvo em %s (%.1f KB)", output, size_kb)


if __name__ == "__main__":
    main()
