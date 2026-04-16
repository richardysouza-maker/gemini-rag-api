export function errorHandler(err, req, res, _next) {
  console.error(`[ERROR] ${err.message}`);

  // Erros do Gemini API
  if (err.status) {
    return res.status(err.status).json({
      error: err.message,
      details: err.errorDetails ?? null,
    });
  }

  // Erros do Multer
  if (err.code === "LIMIT_FILE_SIZE") {
    return res.status(413).json({ error: "Arquivo muito grande. Limite: 50MB." });
  }

  res.status(500).json({
    error: "Erro interno do servidor.",
    details: process.env.NODE_ENV === "development" ? err.message : undefined,
  });
}
