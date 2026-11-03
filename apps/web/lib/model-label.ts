/** Readable name for an Ollama model: hf.co/owner/Llama-3.2-3B-Instruct-GGUF:Q4_K_M → Llama 3.2 3B Instruct · Q4_K_M. */
export function modelLabel(name: string): string {
  const match = /^hf\.co\/[^/]+\/([^:]+)(?::(.+))?$/.exec(name);
  if (!match) return name;
  const base = (match[1] ?? '').replace(/[-_.]?GGUF$/i, '').replace(/-/g, ' ');
  return match[2] ? `${base} · ${match[2]}` : base;
}
