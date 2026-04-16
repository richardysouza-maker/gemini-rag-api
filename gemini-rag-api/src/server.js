import express from "express";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { uploadRouter } from "./routes/upload.js";
import { chatRouter } from "./routes/chat.js";
import { storeRouter } from "./routes/store.js";
import { errorHandler } from "./middleware/errorHandler.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
const PORT = process.env.PORT || 3099;

app.use(express.json());

// Página de teste (UI)
app.use(express.static(join(__dirname, "../public")));

// Rotas
app.use("/api/stores", storeRouter);
app.use("/api/upload", uploadRouter);
app.use("/api/chat", chatRouter);

// Health check
app.get("/health", (req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
});

// Handler de erros
app.use(errorHandler);

app.listen(PORT, () => {
  console.log(`🚀 Gemini RAG API rodando em http://localhost:${PORT}`);
  console.log(`\nEndpoints disponíveis:`);
  console.log(`  POST   /api/stores          - Criar novo File Search Store`);
  console.log(`  GET    /api/stores          - Listar stores`);
  console.log(`  DELETE /api/stores/:name    - Deletar store`);
  console.log(`  POST   /api/upload          - Upload de arquivo para um store`);
  console.log(`  GET    /api/upload/:store   - Listar documentos de um store`);
  console.log(`  DELETE /api/upload/:docName - Deletar documento`);
  console.log(`  POST   /api/chat            - Interagir com o RAG via prompt`);
});

export default app;
