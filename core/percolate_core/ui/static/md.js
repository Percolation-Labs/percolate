/* Markdown to DOM. No library, no innerHTML, no sanitiser needed.
 *
 * The safety argument is structural rather than defensive: this builds nodes
 * and sets `textContent`, so there is no parse step where a `<script>` could
 * survive as markup. A renderer that produced an HTML string would need a
 * sanitiser after it, and the sanitiser would be the thing to get right.
 * Model output is untrusted text — it is written by a model, quoting documents
 * a user uploaded — so "cannot inject" beats "we strip the dangerous parts".
 *
 * The subset is what an agent actually emits: fenced code, headings, bold,
 * italic, inline code, links, lists, blockquotes, rules, pipe tables. Not a
 * CommonMark implementation and not trying to be — anything unrecognised falls
 * through as text, which is the correct failure for a chat transcript.
 */

const el = (tag, cls) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  return n;
};

/* Only these schemes become links. A `javascript:` href is the one XSS a
   text-node renderer would otherwise still allow. */
const SAFE_URL = /^(https?:|mailto:|#|\/)/i;

/** Inline: `code`, **bold**, *italic*, [text](url). Emitted as nodes, in order. */
function inline(text, into) {
  const pattern = /(`[^`]+`)|(\*\*.+?\*\*)|(\*[^*\n]+\*|(?<![\p{L}\p{N}_])_[^_\n]+_(?![\p{L}\p{N}_]))|(\[[^\]]+\]\([^)\s]+\))/gu;
  let last = 0, m;
  while ((m = pattern.exec(text)) !== null) {
    if (m.index > last) into.append(document.createTextNode(text.slice(last, m.index)));
    const tok = m[0];
    if (tok.startsWith("`")) {
      const c = el("code");
      c.textContent = tok.slice(1, -1);
      into.append(c);
    } else if (tok.startsWith("**")) {
      // Recurse: emphasis wrapping code is ordinary in model output
      // (**`batch_size`**), and setting textContent here rendered the
      // backticks. Found by reading a real transcript, not by construction.
      inline(tok.slice(2, -2), into.appendChild(el("strong")));
    } else if (tok.startsWith("[")) {
      const close = tok.indexOf("](");
      const label = tok.slice(1, close), href = tok.slice(close + 2, -1);
      if (SAFE_URL.test(href)) {
        const a = el("a");
        a.textContent = label;
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        into.append(a);
      } else {
        // Not a link, and not silently dropped either: the text stays visible
        // so a reader can see what was there.
        into.append(document.createTextNode(label + " (" + href + ")"));
      }
    } else {
      inline(tok.slice(1, -1), into.appendChild(el("em")));
    }
    last = m.index + tok.length;
  }
  if (last < text.length) into.append(document.createTextNode(text.slice(last)));
  return into;
}

const cells = (row) => row.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());

/** Block-level. Returns one element holding the rendered document. */
export function markdown(src) {
  const root = el("div", "md");
  const lines = String(src == null ? "" : src).replace(/\r\n?/g, "\n").split("\n");
  let i = 0;

  const flushParagraph = (buf) => {
    if (!buf.length) return;
    inline(buf.join(" "), root.appendChild(el("p")));
    buf.length = 0;
  };
  const para = [];

  while (i < lines.length) {
    const line = lines[i];

    if (/^```/.test(line)) {                                   // fenced code
      flushParagraph(para);
      const lang = line.slice(3).trim();
      const body = [];
      i++;
      while (i < lines.length && !/^```/.test(lines[i])) body.push(lines[i++]);
      i++;
      const pre = el("pre", "code");
      pre.textContent = body.join("\n");
      if (lang) pre.dataset.lang = lang;
      root.append(pre);
      continue;
    }

    if (/^\s*$/.test(line)) { flushParagraph(para); i++; continue; }

    const head = /^(#{1,4})\s+(.*)$/.exec(line);
    if (head) {
      flushParagraph(para);
      inline(head[2], root.appendChild(el("h" + (head[1].length + 2))));
      i++;
      continue;
    }

    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {                  // ---
      flushParagraph(para);
      root.append(el("hr"));
      i++;
      continue;
    }

    if (/^>\s?/.test(line)) {                                  // blockquote
      flushParagraph(para);
      const q = el("blockquote");
      const body = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) body.push(lines[i++].replace(/^>\s?/, ""));
      q.append(markdown(body.join("\n")));
      root.append(q);
      continue;
    }

    if (/^\s*\|.*\|\s*$/.test(line) && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1] || "")) {
      flushParagraph(para);                                     // pipe table
      const table = el("table", "md-table");
      const thead = table.appendChild(el("thead")).appendChild(el("tr"));
      cells(line).forEach((c) => inline(c, thead.appendChild(el("th"))));
      i += 2;
      const tbody = table.appendChild(el("tbody"));
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        const tr = tbody.appendChild(el("tr"));
        cells(lines[i++]).forEach((c) => inline(c, tr.appendChild(el("td"))));
      }
      root.append(table);
      continue;
    }

    const item = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (item) {                                                 // list
      flushParagraph(para);
      const ordered = /\d/.test(item[2]);
      const list = el(ordered ? "ol" : "ul");
      while (i < lines.length) {
        const it = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(lines[i]);
        if (!it || /\d/.test(it[2]) !== ordered) break;
        i++;
        /* Lazy continuation. A wrapped item is the normal case in anything a
           model writes to 80 columns, and without this each wrapped line fell
           out of the list and became its own paragraph -- which also restarted
           the numbering, so a three-item list rendered as three "1."s. */
        const parts = [it[3]];
        while (i < lines.length
               && !/^\s*$/.test(lines[i])
               && !/^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i])
               && !/^(#{1,4}\s|```|>|\s*\|)/.test(lines[i])) {
          parts.push(lines[i].trim());
          i++;
        }
        inline(parts.join(" "), list.appendChild(el("li")));
      }
      root.append(list);
      continue;
    }

    para.push(line);
    i++;
  }
  flushParagraph(para);
  return root;
}
