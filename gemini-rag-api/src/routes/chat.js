import { Router } from "express";
import client from "../lib/geminiClient.js";

export const chatRouter = Router();

// Histórico em memória por sessão (simples, sem persistência)
const sessions = new Map();

/**
 * POST /api/chat
 * Envia um prompt e recebe resposta fundamentada nos documentos do store
 *
 * Body:
 *   - prompt: string (obrigatório)
 *   - storeName: ID do store, ex: "abc123" (obrigatório)
 *   - sessionId: string para manter histórico de conversa (opcional)
 *   - systemPrompt: instrução de sistema personalizada (opcional)
 *   - metadataFilter: filtro de metadados, ex: 'author = "João"' (opcional)
 *   - stream: boolean — usa streaming (opcional, default false)
 */
chatRouter.post("/", async (req, res, next) => {
  try {
    const {
      prompt,
      storeName,
      sessionId,
      systemPrompt,
      metadataFilter,
      stream = false,
    } = req.body;

    if (!prompt) {
      return res.status(400).json({ error: "prompt é obrigatório." });
    }

    if (!storeName) {
      return res.status(400).json({ error: "storeName é obrigatório." });
    }

    const fullStoreName = `fileSearchStores/${storeName}`;

    // Monta a ferramenta de busca
    const fileSearchTool = {
      fileSearch: {
        fileSearchStoreNames: [fullStoreName],
        ...(metadataFilter && { metadataFilter }),
      },
    };

    // Gerencia histórico de conversa por sessão
    let history = [];
    if (sessionId) {
      history = sessions.get(sessionId) || [];
    }

    // Adiciona a mensagem atual ao histórico
    const newMessage = { role: "user", parts: [{ text: prompt }] };

    // Monta configuração da geração
    const generateConfig = {
      model: "gemini-2.5-flash",
      contents: [...history, newMessage],
      config: {
        tools: [fileSearchTool],
        ...(systemPrompt && {
          systemInstruction: { parts: [{ text: systemPrompt }] },
        }),
      },
    };

    // Modo streaming
    if (stream) {
      res.setHeader("Content-Type", "text/event-stream");
      res.setHeader("Cache-Control", "no-cache");
      res.setHeader("Connection", "keep-alive");

      let fullText = "";

      const streamResponse =
        await client.models.generateContentStream(generateConfig);

      for await (const chunk of streamResponse) {
        const text = chunk.text ?? "";
        fullText += text;

        if (text) {
          res.write(`data: ${JSON.stringify({ text })}\n\n`);
        }
      }

      // Salva resposta no histórico
      if (sessionId) {
        history.push(newMessage);
        history.push({ role: "model", parts: [{ text: fullText }] });
        sessions.set(sessionId, history);
      }

      res.write(`data: ${JSON.stringify({ done: true })}\n\n`);
      res.end();
      return;
    }

    // Modo normal (sem streaming)
    const response = await client.models.generateContent(generateConfig);

    const text = response.text;

    // Extrai fontes usadas
    const grounding = response.candidates?.[0]?.groundingMetadata;
    const sources = grounding?.groundingChunks
      ? [
          ...new Set(
            grounding.groundingChunks
              .map((c) => c.retrievedContext?.title)
              .filter(Boolean)
          ),
        ]
      : [];

    // Salva no histórico da sessão
    if (sessionId) {
      history.push(newMessage);
      history.push({ role: "model", parts: [{ text }] });
      sessions.set(sessionId, history);
    }

    res.json({
      answer: text,
      sources,
      sessionId: sessionId || null,
      historyLength: sessionId ? sessions.get(sessionId).length / 2 : 0,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * DELETE /api/chat/session/:sessionId
 * Limpa o histórico de uma sessão
 */
chatRouter.delete("/session/:sessionId", (req, res) => {
  const { sessionId } = req.params;
  sessions.delete(sessionId);
  res.json({ message: `Sessão '${sessionId}' limpa com sucesso.` });
});
