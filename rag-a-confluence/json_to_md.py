"""
Converte confluence_kb_*.json em um unico arquivo Markdown pronto
para upload no Gemini File Search.

Uso:
    python json_to_md.py                    # auto-detecta o JSON mais recente
    python json_to_md.py meu_arquivo.json
"""

import glob
import json
import os
import sys
from datetime import datetime


def json_to_md(input_file: str, output_file: str) -> None:
    with open(input_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    with open(output_file, "w", encoding="utf-8") as md:
        md.write("# Confluence Knowledge Base\n\n")
        md.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        md.write(f"Total Articles: {len(data)}\n\n")
        md.write("---\n\n")

        for article in data:
            title = article.get("title") or "Sem título"
            md.write(f"# {title}\n\n")

            md.write("### Metadata\n")
            if article.get("id"):
                md.write(f"- **ID**: {article['id']}\n")
            if article.get("type"):
                md.write(f"- **Type**: {article['type']}\n")
            if article.get("space_key"):
                md.write(f"- **Space**: {article['space_key']}\n")
            if article.get("parent_id"):
                md.write(f"- **Parent ID**: {article['parent_id']}\n")
            if article.get("url"):
                md.write(f"- **URL**: {article['url']}\n")
            if article.get("modified_time"):
                md.write(f"- **Last Modified**: {article['modified_time']}\n")
            if article.get("version"):
                md.write(f"- **Version**: {article['version']}\n")
            md.write("\n")

            content = (article.get("content") or "").strip()
            if content:
                md.write("### Content\n")
                md.write(content)
                md.write("\n\n")

            md.write("---\n\n")

    print(f"Successfully created {output_file}")


if __name__ == "__main__":
    current_dir = os.path.dirname(os.path.abspath(__file__))

    if len(sys.argv) > 1:
        input_path = sys.argv[1]
        if not os.path.isabs(input_path):
            input_path = os.path.join(current_dir, input_path)
    else:
        pattern = os.path.join(current_dir, "confluence_kb_*.json")
        candidates = sorted(glob.glob(pattern))
        if not candidates:
            print("Erro: nenhum confluence_kb_*.json encontrado. Rode generate_confluence_kb.py primeiro.")
            sys.exit(1)
        input_path = candidates[-1]

    output_path = input_path.replace(".json", ".md")
    json_to_md(input_path, output_path)
