"""
RAG com Gemini File Search API.

Uso:
    # 1) Criar o store e fazer upload do .md (só precisa rodar uma vez)
    python gemini_rag.py upload full_kb_dataset_2026-04-09.cleaned.md

    # 2) Perguntas one-shot (sem prompt/historico)
    python gemini_rag.py ask "Como cadastrar horários de sessões?"

    # 3) Chat interativo simulando producao (usa prompt.md como system prompt)
    python gemini_rag.py chat
    python gemini_rag.py chat prompt.md   # caminho customizado

    # 4) Listar stores existentes
    python gemini_rag.py list

    # 5) Deletar um store
    python gemini_rag.py delete fileSearchStores/xxxxx

O nome do store criado é salvo em .gemini_store para reuso automático.
"""

import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv()

API_KEY = os.getenv("GEMINI_API_KEY")
if not API_KEY:
    sys.exit("ERRO: defina GEMINI_API_KEY no arquivo .env")

MODEL = "gemini-2.5-flash"
STORE_REF_FILE = Path(".gemini_store")

client = genai.Client(api_key=API_KEY)


def _save_store_name(name: str) -> None:
    STORE_REF_FILE.write_text(name.strip())


def _load_store_name() -> str:
    if not STORE_REF_FILE.exists():
        sys.exit(
            "ERRO: nenhum store salvo em .gemini_store. "
            "Rode primeiro: python gemini_rag.py upload <arquivo.md>"
        )
    return STORE_REF_FILE.read_text().strip()


def upload(file_path: str) -> None:
    path = Path(file_path)
    if not path.exists():
        sys.exit(f"ERRO: arquivo nao encontrado: {file_path}")

    print(f"Criando File Search Store...")
    store = client.file_search_stores.create(
        config={"display_name": f"kb-{path.stem}"}
    )
    print(f"Store criado: {store.name}")

    print(f"Enviando {path.name} ({path.stat().st_size / 1024:.1f} KB)...")
    operation = client.file_search_stores.upload_to_file_search_store(
        file=str(path),
        file_search_store_name=store.name,
        config={"display_name": path.name},
    )

    print("Indexando (isso pode levar alguns minutos)...")
    while not operation.done:
        time.sleep(5)
        operation = client.operations.get(operation)
        print("  ...aguardando indexacao")

    _save_store_name(store.name)
    print(f"\nPronto! Store salvo em {STORE_REF_FILE}")
    print(f"Agora voce pode fazer perguntas com: python gemini_rag.py ask \"sua pergunta\"")


def ask(question: str) -> None:
    store_name = _load_store_name()
    print(f"Consultando store: {store_name}\n")

    response = client.models.generate_content(
        model=MODEL,
        contents=question,
        config=types.GenerateContentConfig(
            tools=[
                types.Tool(
                    file_search=types.FileSearch(
                        file_search_store_names=[store_name]
                    )
                )
            ]
        ),
    )

    print("=" * 60)
    print("RESPOSTA:")
    print("=" * 60)
    print(response.text)

    # Citacoes (grounding)
    try:
        metadata = response.candidates[0].grounding_metadata
        if metadata and metadata.grounding_chunks:
            print("\n" + "=" * 60)
            print("FONTES:")
            print("=" * 60)
            for i, chunk in enumerate(metadata.grounding_chunks, 1):
                if hasattr(chunk, "retrieved_context") and chunk.retrieved_context:
                    title = getattr(chunk.retrieved_context, "title", "sem titulo")
                    print(f"  [{i}] {title}")
    except (AttributeError, IndexError):
        pass


def chat(prompt_path: str = "prompt.md") -> None:
    """Chat interativo multi-turn simulando o ambiente de producao."""
    store_name = _load_store_name()

    prompt_file = Path(prompt_path)
    if not prompt_file.exists():
        sys.exit(
            f"ERRO: arquivo de prompt nao encontrado: {prompt_path}\n"
            f"Crie um arquivo com o system prompt (ex: prompt.md) e rode de novo."
        )
    system_instruction = prompt_file.read_text().strip()
    if not system_instruction:
        sys.exit(f"ERRO: {prompt_path} esta vazio.")

    print("=" * 60)
    print("CHAT INTERATIVO — simulando producao")
    print("=" * 60)
    print(f"Store:  {store_name}")
    print(f"Prompt: {prompt_path} ({len(system_instruction)} chars)")
    print(f"Modelo: {MODEL}")
    print()
    print("Digite sua pergunta. Comandos: /reset (limpa historico), /sair")
    print("=" * 60)
    print()

    config = types.GenerateContentConfig(
        system_instruction=system_instruction,
        tools=[
            types.Tool(
                file_search=types.FileSearch(
                    file_search_store_names=[store_name]
                )
            )
        ],
    )

    chat_session = client.chats.create(model=MODEL, config=config)

    while True:
        try:
            user_input = input("Voce: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAte mais!")
            break

        if not user_input:
            continue
        if user_input.lower() in ("/sair", "/exit", "/quit"):
            print("Ate mais!")
            break
        if user_input.lower() == "/reset":
            chat_session = client.chats.create(model=MODEL, config=config)
            print("(historico limpo)\n")
            continue

        try:
            response = chat_session.send_message(user_input)
        except Exception as e:
            print(f"\nERRO ao consultar Gemini: {e}\n")
            continue

        print(f"\nIA: {response.text}\n")

        # Mostra fontes de forma discreta
        try:
            metadata = response.candidates[0].grounding_metadata
            if metadata and metadata.grounding_chunks:
                n = len(metadata.grounding_chunks)
                print(f"  (fontes consultadas: {n} trecho(s) do RAG)\n")
        except (AttributeError, IndexError):
            pass


def list_stores() -> None:
    stores = list(client.file_search_stores.list())
    if not stores:
        print("Nenhum store encontrado.")
        return
    for s in stores:
        print(f"- {s.name}")
        if hasattr(s, "display_name"):
            print(f"    display_name: {s.display_name}")


def delete_store(name: str) -> None:
    client.file_search_stores.delete(name=name, config={"force": True})
    print(f"Store deletado: {name}")
    if STORE_REF_FILE.exists() and STORE_REF_FILE.read_text().strip() == name:
        STORE_REF_FILE.unlink()


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "upload":
        if len(sys.argv) < 3:
            sys.exit("Uso: python gemini_rag.py upload <arquivo.md>")
        upload(sys.argv[2])
    elif cmd == "ask":
        if len(sys.argv) < 3:
            sys.exit('Uso: python gemini_rag.py ask "sua pergunta"')
        ask(" ".join(sys.argv[2:]))
    elif cmd == "chat":
        prompt_path = sys.argv[2] if len(sys.argv) >= 3 else "prompt.md"
        chat(prompt_path)
    elif cmd == "list":
        list_stores()
    elif cmd == "delete":
        if len(sys.argv) < 3:
            sys.exit("Uso: python gemini_rag.py delete <nome-do-store>")
        delete_store(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
