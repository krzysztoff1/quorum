const STOPWORDS: Record<string, string[]> = {
  en: ["the", "and", "of", "to", "in", "is", "what", "for", "from", "when", "do", "does", "are", "with", "which", "how",
       "that", "has", "have", "a", "an", "it", "on", "by", "or", "can", "will", "should", "why", "who", "where", "was"],
  pl: ["i", "w", "z", "na", "do", "o", "jakie", "jak", "czy", "się", "dla", "od", "są", "nie", "oraz", "dotyczą", "które"],
  de: ["und", "der", "die", "das", "von", "für", "ist", "welche", "wie", "ab", "wann", "mit", "nicht", "sie", "gelten"],
  fr: ["le", "la", "les", "des", "et", "de", "du", "est", "sont", "quelles", "quand", "pour", "à", "partir"],
  es: ["el", "la", "los", "las", "de", "y", "son", "cuáles", "desde", "cuándo", "para", "se", "con", "del"],
};

const POLISH_LETTERS = /[ąćęłńśźż]/i;
const MIN_HITS = 1;

export function detectLanguage(text: string): string {
  const words = text.toLowerCase().split(/[\s\p{P}\p{S}]+/u).filter((w) => /^\p{L}+$/u.test(w));
  let best = "und";
  let bestScore = 0;
  for (const [language, stopwords] of Object.entries(STOPWORDS)) {
    const set = new Set(stopwords);
    let score = words.filter((w) => set.has(w)).length;
    if (language === "pl" && POLISH_LETTERS.test(text)) score += 2;
    if (score > bestScore) {
      best = language;
      bestScore = score;
    }
  }
  return bestScore >= MIN_HITS ? best : "und";
}
