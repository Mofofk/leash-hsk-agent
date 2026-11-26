// Google Gemini (AI Studio) client. Key from GEMINI_API_KEY; in the Hark sandbox it is injected by the host.
const MODELS = () => (process.env.GEMINI_MODELS || "gemini-3-flash-preview,gemini-3.5-flash-lite,gemini-3.5-flash,gemini-3.8-flash,gemini-flash-latest").split(",");

export async function geminiJSON(system, user, { temperature = 0.2, timeoutMs = 25000 } = {}) {
  let lastErr;
  for (let round = 0; round < 3; round++) {
    for (const model of MODELS()) {
      try {
        const headers = { "content-type": "application/json" };
        if (process.env.GEMINI_API_KEY) headers["x-goog-api-key"] = process.env.GEMINI_API_KEY;
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: "POST",
          headers,
          signal: AbortSignal.timeout(timeoutMs),
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: system }] },
            contents: [{ role: "user", parts: [{ text: user }] }],
            generationConfig: { temperature, responseMimeType: "application/json" },
          }),
        });
        const d = await r.json();
        if (!r.ok) throw new Error(`${model}: ${d?.error?.message || r.status}`);
        const text = d.candidates?.[0]?.content?.parts?.map((p) => (p.thought ? "" : p.text || "")).join("") || "";
        return { model, data: JSON.parse(text.replace(/^```json\s*|```$/g, "")) };
      } catch (e) {
        lastErr = e;
        await new Promise((res) => setTimeout(res, 1500));
      }
    }
  }
  throw lastErr;
}
