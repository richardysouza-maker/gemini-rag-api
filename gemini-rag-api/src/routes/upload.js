import { Router } from "express";
import multer from "multer";
import fs from "fs";
import path from "path";
import client from "../lib/geminiClient.js";

export const uploadRouter = Router();

// Multer: armazena em disco temporariamente
const upload = multer({
  dest: "tmp/",
  limits: { fileSize: 50 * 1024 * 1024 }, // 50MB
});

/**
 * POST /api/upload
 * Faz upload de um arquivo para um File Search Store existente
 * Form-data:
 *   - file: arquivo (obrigatório)
 *   - storeName: ID do store, ex: "abc123" (obrigatório)
 *   - displayName: nome amigável do documento (opcional)
 *   - metadata: JSON string com metadados chave-valor (opcional)
 *     Ex: '{"author":"João","year":"2025"}'
 */
uploadRouter.post("/", upload.single("file"), async (req, res, next) => {
  const tmpPath = req.file?.path;

  try {
    if (!req.file) {
      return res.status(400).json({ error: "Nenhum arquivo enviado." });
    }

    const { storeName, displayName, metadata } = req.body;

    if (!storeName) {
      return res.status(400).json({ error: "storeName é obrigatório." });
    }

    const fullStoreName = `fileSearchStores/${storeName}`;
    const docDisplayName = displayName || req.file.originalname;

    // Monta config com metadados opcionais
    const config = { displayName: docDisplayName };

    if (metadata) {
      try {
        const parsed = JSON.parse(metadata);
        config.customMetadata = Object.entries(parsed).map(([key, value]) => ({
          key,
          value,
        }));
      } catch {
        return res
          .status(400)
          .json({ error: "metadata deve ser um JSON válido." });
      }
    }

    // Lê o arquivo do disco
    const fileBuffer = fs.readFileSync(tmpPath);
    const mimeType = req.file.mimetype;

    // Faz upload para o File Search Store (retorna Operation, não Document)
    const operation = await client.fileSearchStores.uploadToFileSearchStore({
      fileSearchStoreName: fullStoreName,
      file: new Blob([fileBuffer], { type: mimeType }),
      config,
    });

    // Extrai o nome do documento da operação
    const documentName = operation?.response?.documentName;

    // Faz poll do documento para obter o estado real (máx ~10s)
    let document = null;
    if (documentName) {
      for (let i = 0; i < 5; i++) {
        await new Promise((r) => setTimeout(r, 2000));
        try {
          document = await client.fileSearchStores.documents.get({
            name: documentName,
          });
          // Sai do loop se chegou a um estado final
          if (
            document.state === "STATE_ACTIVE" ||
            document.state === "STATE_FAILED"
          ) {
            break;
          }
        } catch (_) {
          break;
        }
      }
    }

    res.status(201).json({
      message: "Arquivo enviado com sucesso.",
      operation: {
        name: operation.name,
        done: operation.done,
        error: operation.error ?? null,
        documentName,
      },
      document: document
        ? {
            name: document.name,
            displayName: document.displayName,
            mimeType: document.mimeType,
            createTime: document.createTime,
            updateTime: document.updateTime,
            state: document.state,
            sizeBytes: document.sizeBytes,
          }
        : null,
    });
  } catch (err) {
    next(err);
  } finally {
    // Limpa arquivo temporário
    if (tmpPath && fs.existsSync(tmpPath)) {
      fs.unlinkSync(tmpPath);
    }
  }
});

/**
 * GET /api/upload/:storeName
 * Lista todos os documentos de um store
 */
uploadRouter.get("/:storeName", async (req, res, next) => {
  try {
    const { storeName } = req.params;
    const fullStoreName = `fileSearchStores/${storeName}`;

    const result = await client.fileSearchStores.documents.listInternal({
      parent: fullStoreName,
    });
    const documents = (result.documents || []).map((doc) => ({
      name: doc.name,
      displayName: doc.displayName,
      mimeType: doc.mimeType,
      createTime: doc.createTime,
      updateTime: doc.updateTime,
      state: doc.state,
      sizeBytes: doc.sizeBytes,
    }));

    res.json({ documents, total: documents.length });
  } catch (err) {
    next(err);
  }
});

/**
 * DELETE /api/upload/:storeName/:docId
 * Deleta um documento específico de um store
 */
uploadRouter.delete("/:storeName/:docId", async (req, res, next) => {
  try {
    const { storeName, docId } = req.params;
    const docName = `fileSearchStores/${storeName}/documents/${docId}`;

    await client.fileSearchStores.documents.delete({
      name: docName,
      config: { force: true },
    });

    res.json({ message: `Documento '${docName}' deletado com sucesso.` });
  } catch (err) {
    next(err);
  }
});
