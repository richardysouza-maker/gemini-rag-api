import { Router } from "express";
import client from "../lib/geminiClient.js";

export const storeRouter = Router();

/**
 * POST /api/stores
 * Cria um novo File Search Store
 * Body: { displayName: string }
 */
storeRouter.post("/", async (req, res, next) => {
  try {
    const { displayName } = req.body;

    if (!displayName) {
      return res.status(400).json({ error: "displayName é obrigatório." });
    }

    const store = await client.fileSearchStores.create({
      config: { displayName },
    });

    res.status(201).json({
      message: "Store criado com sucesso.",
      store: {
        name: store.name,
        displayName: store.displayName,
        createTime: store.createTime,
      },
    });
  } catch (err) {
    next(err);
  }
});

/**
 * GET /api/stores
 * Lista todos os File Search Stores
 */
storeRouter.get("/", async (req, res, next) => {
  try {
    const result = await client.fileSearchStores.listInternal({});
    const stores = (result.fileSearchStores || []).map((store) => ({
      name: store.name,
      displayName: store.displayName,
      createTime: store.createTime,
      updateTime: store.updateTime,
      activeDocumentsCount: store.activeDocumentsCount,
      sizeBytes: store.sizeBytes,
    }));

    res.json({ stores, total: stores.length });
  } catch (err) {
    next(err);
  }
});

/**
 * DELETE /api/stores/:storeName
 * Deleta um store e todos os seus documentos
 * Params: storeName - ID do store (sem "fileSearchStores/", apenas o ID)
 */
storeRouter.delete("/:storeName", async (req, res, next) => {
  try {
    const { storeName } = req.params;
    const fullName = `fileSearchStores/${storeName}`;

    await client.fileSearchStores.delete({
      name: fullName,
      config: { force: true },
    });

    res.json({ message: `Store '${fullName}' deletado com sucesso.` });
  } catch (err) {
    next(err);
  }
});
