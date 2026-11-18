import MarkdownIt from "markdown-it";
import DOMPurify from "dompurify";
import mermaid from "mermaid";

const renderer = new MarkdownIt({ html: true, linkify: false });
const defaultFence = renderer.renderer.rules.fence;
renderer.renderer.rules.fence = (tokens, index, options, environment, self) => {
  const token = tokens[index];
  if (token.info.trim().toLowerCase() !== "mermaid") {
    return defaultFence(tokens, index, options, environment, self);
  }
  return '<pre class="diagram-source"><code>' + renderer.utils.escapeHtml(token.content) + "</code></pre>";
};

let revision = 0;

window.renderPaperNotes = async (pages, annotations, dark, accent, english) => {
  const run = ++revision;
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  document.documentElement.lang = english ? "en" : "zh-CN";
  if (/^#[0-9a-f]{6}$/i.test(accent)) document.documentElement.style.setProperty("--accent", accent);
  const main = document.querySelector("main");
  main.setAttribute("aria-label", english ? "Markdown preview" : "Markdown 预览");
  const fragment = document.createDocumentFragment();
  for (const { id, markdown } of pages) {
    const section = document.createElement("section");
    section.id = "page-" + id;
    section.innerHTML = DOMPurify.sanitize(renderer.render(markdown), {
      ALLOWED_TAGS: ["h1", "h2", "h3", "h4", "h5", "h6", "p", "ul", "ol", "li",
        "strong", "em", "u", "s", "del", "a", "blockquote", "pre", "code", "br",
        "hr", "sub", "sup", "table", "thead", "tbody", "tr", "th", "td"],
      ALLOWED_ATTR: ["href", "class", "start"]
    });
    fragment.append(section);
  }
  main.replaceChildren(fragment);

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    htmlLabels: false,
    theme: "base",
    themeVariables: {
      darkMode: dark,
      fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
      primaryColor: dark ? "#292830" : "#F5F4F8",
      primaryBorderColor: accent || (dark ? "#aa97fa" : "#7862da"),
      primaryTextColor: dark ? "#F3F0F6" : "#242230",
      lineColor: accent || (dark ? "#b2a5da" : "#776799"),
      tertiaryColor: dark ? "#232229" : "#f6f5f8"
    }
  });

  let index = 0;
  for (const block of main.querySelectorAll(".diagram-source")) {
    const source = block.textContent;
    try {
      if (!/^\s*(flowchart|graph)\b/.test(source) || source.length > 30000) continue;
      // Keep diagram directives and front matter from altering the preview configuration.
      const clean = source.replace(/%%\{[\s\S]*?\}%%/g, "");
      const { svg } = await mermaid.render("paper-diagram-" + run + "-" + ++index, clean);
      if (run !== revision) return;
      const diagram = document.createElement("figure");
      diagram.className = "diagram";
      diagram.innerHTML = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true } });
      block.replaceWith(diagram);
    } catch {
      // Leave the editable source available when a diagram contains invalid syntax.
    }
  }
  if (run === revision) addAnnotations(annotations, english);
};

function textAnchor(section, anchor) {
  if (!anchor) return null;
  let range = null;
  for (const block of section.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,td,th")) {
    if (block.querySelector("p,li")) continue;
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let content = "";
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (node.parentElement.closest(".review-badge")) continue;
      content += node.data;
      nodes.push(node);
    }
    const start = content.indexOf(anchor);
    if (start < 0) continue;
    if (range || content.indexOf(anchor, start + 1) >= 0) return null;
    let offset = start + anchor.length;
    for (const node of nodes) {
      if (offset <= node.length) {
        range = document.createRange();
        range.setStart(node, offset);
        range.collapse(true);
        break;
      }
      offset -= node.length;
    }
  }
  return range;
}

function addAnnotations(annotations, english) {
  for (const item of annotations) {
    const section = document.getElementById("page-" + item.section);
    if (!section) continue;
    const button = document.createElement("button");
    button.type = "button";
    button.id = "issue-" + item.id;
    const action = item.kind === "todo" || item.kind === "event";
    button.className = action ? "review-badge action-badge" : "review-badge";
    const kind = item.label || (english ? "Note" : "注释");
    button.textContent = action ? kind + " " + item.number : item.number;
    button.setAttribute("aria-label", kind + " " + item.number + (english ? ", " : "，") + item.category);
    button.title = (english ? "View " : "查看") + kind + " " + item.number + " · " + item.category;
    button.onclick = () => window.webkit.messageHandlers.paperReview.postMessage(item.id);

    const anchor = item.anchor.trim();
    const placement = textAnchor(section, anchor);
    if (placement) {
      const link = placement.startContainer.parentElement.closest("a");
      if (link) link.after(button);
      else placement.insertNode(button);
      continue;
    }
    const diagrams = action ? [] : [...section.querySelectorAll("figure.diagram")];
    const matching = diagrams.filter((figure) => anchor && figure.querySelector("svg")?.textContent.includes(anchor));
    const diagram = matching.length === 1 ? matching[0] :
      (diagrams.length === 1 && /箭头|连线|节点|框图/.test(item.category) ? diagrams[0] : null);
    if (diagram) {
      let pins = diagram.querySelector(":scope > .review-figure-pins");
      if (!pins) {
        pins = document.createElement("div");
        pins.className = "review-figure-pins";
        diagram.append(pins);
      }
      pins.append(button);
      continue;
    }
    let margin = section.querySelector(":scope > .review-gutter");
    if (!margin) {
      margin = document.createElement("aside");
      margin.className = "review-gutter";
      section.prepend(margin);
    }
    margin.append(button);
  }
}

window.focusPaperAnnotation = (pageID, issueID) => {
  for (const button of document.querySelectorAll(".review-badge.active")) {
    button.classList.remove("active");
  }
  if (!issueID) return;
  const button = document.getElementById("issue-" + issueID);
  if (button) {
    button.classList.add("active");
    button.scrollIntoView({ block: "nearest", behavior: "auto" });
  } else {
    document.getElementById("page-" + pageID)?.scrollIntoView({ block: "start", behavior: "auto" });
  }
};
