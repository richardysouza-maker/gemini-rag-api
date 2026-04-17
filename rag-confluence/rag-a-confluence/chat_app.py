"""
Interface visual de chat para testar o RAG Confluence.

Uso:
    streamlit run chat_app.py
"""

import os
from pathlib import Path

import streamlit as st
from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv()

API_KEY = os.getenv("GEMINI_API_KEY")
MODEL = "gemini-2.5-flash"
STORE_REF_FILE = Path(".gemini_store")
PROMPT_FILE = Path("prompt.md")

st.set_page_config(
    page_title="Chat Base Confluence",
    page_icon="💬",
    layout="wide",
)


def _error(msg: str) -> None:
    st.error(msg)
    st.stop()


if not API_KEY:
    _error("GEMINI_API_KEY não definida. Preencha o .env e reinicie o servidor.")

if not STORE_REF_FILE.exists():
    _error(
        "Nenhum store do Gemini encontrado.\n\n"
        "Rode primeiro:\n"
        "```\npython gemini_rag.py upload confluence_kb_YYYY-MM-DD.md\n```"
    )

STORE_NAME = STORE_REF_FILE.read_text().strip()
SYSTEM_PROMPT = PROMPT_FILE.read_text().strip() if PROMPT_FILE.exists() else ""


@st.cache_resource
def get_client() -> genai.Client:
    return genai.Client(api_key=API_KEY)


def new_chat_session(client: genai.Client):
    config = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT or None,
        tools=[
            types.Tool(
                file_search=types.FileSearch(
                    file_search_store_names=[STORE_NAME]
                )
            )
        ],
    )
    return client.chats.create(model=MODEL, config=config)


client = get_client()

if "messages" not in st.session_state:
    st.session_state.messages = []
if "chat" not in st.session_state:
    st.session_state.chat = new_chat_session(client)

# ---------- Sidebar ----------
with st.sidebar:
    st.markdown("### Configuração")
    st.caption(f"**Modelo**")
    st.code(MODEL, language=None)
    st.caption(f"**Store**")
    st.code(STORE_NAME, language=None)
    st.caption(f"**System prompt**")
    st.code(f"{len(SYSTEM_PROMPT)} chars" if SYSTEM_PROMPT else "(nenhum)", language=None)

    st.divider()
    if st.button("Nova conversa", use_container_width=True):
        st.session_state.messages = []
        st.session_state.chat = new_chat_session(client)
        st.rerun()

    st.divider()
    st.caption(
        "Este chat consulta exclusivamente a base indexada no Gemini "
        "File Search. Respostas sem fontes indicam que o conteúdo não "
        "está na base."
    )

# ---------- Main ----------
st.title("Chat — Base de Conhecimento Confluence")
st.caption("Teste o RAG conversando com a base indexada.")

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg.get("sources"):
            with st.expander(f"Fontes consultadas ({len(msg['sources'])})"):
                for i, src in enumerate(msg["sources"], 1):
                    st.caption(f"[{i}] {src}")

if prompt := st.chat_input("Digite sua pergunta..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        with st.spinner("Consultando a base..."):
            try:
                response = st.session_state.chat.send_message(prompt)
                answer = response.text or "(sem resposta)"

                sources: list[str] = []
                try:
                    metadata = response.candidates[0].grounding_metadata
                    if metadata and metadata.grounding_chunks:
                        for chunk in metadata.grounding_chunks:
                            ctx = getattr(chunk, "retrieved_context", None)
                            if ctx:
                                title = getattr(ctx, "title", None) or "sem título"
                                sources.append(title)
                except (AttributeError, IndexError):
                    pass

                st.markdown(answer)
                if sources:
                    with st.expander(f"Fontes consultadas ({len(sources)})"):
                        for i, src in enumerate(sources, 1):
                            st.caption(f"[{i}] {src}")

                st.session_state.messages.append(
                    {"role": "assistant", "content": answer, "sources": sources}
                )
            except Exception as e:
                st.error(f"Erro ao consultar o Gemini: {e}")
