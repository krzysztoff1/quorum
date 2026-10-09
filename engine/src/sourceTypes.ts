export type SourceType = "primary" | "vendor" | "seo" | "academic" | "news";

const ACADEMIC_HOSTS = [
  "arxiv.org", "doi.org", "nature.com", "sciencedirect.com", "springer.com", "link.springer.com", "ieee.org",
  "acm.org", "ncbi.nlm.nih.gov", "nih.gov", "jstor.org", "researchgate.net", "ssrn.com", "semanticscholar.org",
  "biorxiv.org", "medrxiv.org", "wiley.com", "tandfonline.com", "sagepub.com", "plos.org", "science.org",
  "openreview.net", "aclanthology.org", "mdpi.com", "frontiersin.org",
];

const PRIMARY_HOSTS = [
  "europa.eu", "who.int", "un.org", "worldbank.org", "imf.org", "oecd.org", "w3.org", "ietf.org", "iso.org",
  "rfc-editor.org", "wto.org", "bis.org", "ecb.europa.eu", "iea.org", "eurostat.eu", "nist.gov",
];

const NEWS_HOSTS = [
  "reuters.com", "bloomberg.com", "nytimes.com", "wsj.com", "ft.com", "bbc.com", "bbc.co.uk", "theguardian.com",
  "techcrunch.com", "wired.com", "theverge.com", "cnbc.com", "economist.com", "apnews.com", "axios.com",
  "washingtonpost.com", "arstechnica.com", "politico.com", "npr.org", "cnn.com", "theatlantic.com",
  "businessinsider.com", "forbes.com", "fortune.com", "venturebeat.com", "zdnet.com", "euronews.com",
];

const SEO_HOSTS = ["medium.com", "quora.com", "geeksforgeeks.org", "dev.to", "hackernoon.com", "pinterest.com"];

const SEO_PATH = /\/(?:best|top|vs|versus|alternatives|review|reviews|listicle)[-_/]|[-_/](?:best|top)[-_]\d*|[-_]vs[-_]|[-_]alternatives?(?:[-_/]|$)|[-_]ultimate[-_]guide|\/top-?\d+/i;
const SEO_TITLE = /\b(?:best|top)\s+\d+\b|\b\d+\s+best\b|\bultimate guide\b|\bcomplete guide\b|\bbest\s+\w+(?:\s+\w+){0,3}\s+(?:in|for)\s+20\d\d\b|\balternatives\b|\bvs\.?\b/i;

export function classifySource(url: string, title = ""): SourceType {
  const parsed = parse(url);
  if (!parsed) return "vendor";
  const host = parsed.hostname.replace(/^www\./, "").toLowerCase();

  if (isAcademicHost(host)) return "academic";
  if (isPrimaryHost(host)) return "primary";
  if (matchesHost(host, NEWS_HOSTS)) return "news";
  if (matchesHost(host, SEO_HOSTS)) return "seo";
  if (SEO_PATH.test(parsed.pathname) || SEO_TITLE.test(title)) return "seo";
  return "vendor";
}

function parse(url: string): URL | undefined {
  try {
    return new URL(url);
  } catch {
    return undefined;
  }
}

function matchesHost(host: string, list: string[]): boolean {
  return list.some((entry) => host === entry || host.endsWith(`.${entry}`));
}

function isAcademicHost(host: string): boolean {
  return host.endsWith(".edu") || /\.ac\.[a-z]{2}$/.test(host) || /\.edu\.[a-z]{2}$/.test(host) ||
    matchesHost(host, ACADEMIC_HOSTS);
}

function isPrimaryHost(host: string): boolean {
  return host.endsWith(".gov") || /\.gov\.[a-z]{2}$/.test(host) || host.endsWith(".mil") ||
    matchesHost(host, PRIMARY_HOSTS);
}
