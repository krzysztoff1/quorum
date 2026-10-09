import { describe, it, expect } from "vitest";
import { classifySource } from "../src/sourceTypes.js";

describe("classifySource", () => {
  it("calls scholarly hosts academic", () => {
    expect(classifySource("https://arxiv.org/abs/1706.03762")).toBe("academic");
    expect(classifySource("https://cs.stanford.edu/people/x")).toBe("academic");
    expect(classifySource("https://www.ox.ac.uk/research")).toBe("academic");
    expect(classifySource("https://pubmed.ncbi.nlm.nih.gov/123/")).toBe("academic");
    expect(classifySource("https://www.nature.com/articles/s41586")).toBe("academic");
    expect(classifySource("https://en.wikipedia.org/wiki/Global_interpreter_lock")).toBe("academic");
  });

  it("calls governments, regulators and standards bodies primary", () => {
    expect(classifySource("https://www.sec.gov/edgar/search")).toBe("primary");
    expect(classifySource("https://www.ons.gov.uk/economy")).toBe("primary");
    expect(classifySource("https://ec.europa.eu/eurostat")).toBe("primary");
    expect(classifySource("https://www.who.int/news-room")).toBe("primary");
    expect(classifySource("https://www.rfc-editor.org/rfc/rfc9110")).toBe("primary");
    expect(classifySource("https://peps.python.org/pep-0703/")).toBe("primary");
    expect(classifySource("https://docs.python.org/3/howto/free-threading-python.html")).toBe("primary");
    expect(classifySource("https://developer.mozilla.org/en-US/docs/Web/API/fetch")).toBe("primary");
    expect(classifySource("https://www.postgresql.org/docs/current/")).toBe("primary");
  });

  it("calls news organisations news, including their subdomains", () => {
    expect(classifySource("https://www.reuters.com/technology/x")).toBe("news");
    expect(classifySource("https://www.bbc.co.uk/news/business-1")).toBe("news");
    expect(classifySource("https://markets.ft.com/data")).toBe("news");
  });

  it("calls listicles and content farms SEO", () => {
    expect(classifySource("https://acme.com/blog/best-crm-tools-2026")).toBe("seo");
    expect(classifySource("https://acme.com/resources/top-10-crms")).toBe("seo");
    expect(classifySource("https://medium.com/@someone/how-to-x")).toBe("seo");
    expect(classifySource("https://acme.com/post", "The Ultimate Guide to CRMs")).toBe("seo");
    expect(classifySource("https://acme.com/post", "7 Best Food Delivery Apps")).toBe("seo");
  });

  it("falls back to vendor for a commercial site that is not obviously one of the others", () => {
    expect(classifySource("https://acme.com/pricing")).toBe("vendor");
    expect(classifySource("https://acme.com/blog/launching-our-api")).toBe("vendor");
    expect(classifySource("not a url")).toBe("vendor");
  });

  it("lets the host outrank a listicle-looking title", () => {
    expect(classifySource("https://www.reuters.com/x", "Top 10 stories of the year")).toBe("news");
    expect(classifySource("https://arxiv.org/abs/1", "A Best Practices Guide")).toBe("academic");
  });
});
