// The editor's tooltips in the light and the dark scheme, for the browser
// tests of the problems the editor marks (Test.Browser.Problems).

// Put the dark scheme's colours on the open editor's host (.editor-cm), or
// take them off. The wiki's dark colours are the tokens the style sheet
// sets on :root under (prefers-color-scheme: dark); the test's browser is in
// the light scheme, so the tokens are copied from those rules onto the
// host, where the editor and its tooltips inherit them as they would from
// :root. The host is the component's: the tokens leave with it, and no
// other test in the page sees them. False when there is no editor.
function wiki_test_dark_scheme(dark) {
  const hosts = document.querySelectorAll(".editor-cm:not(:empty)");
  const host = hosts[hosts.length - 1];
  if (!host) return false;
  const tokens = [];
  const visit = (rules, inDark) => {
    for (const rule of rules) {
      if (rule instanceof CSSMediaRule) {
        visit(rule.cssRules, inDark || /prefers-color-scheme:\s*dark/.test(rule.conditionText ?? rule.media.mediaText));
      } else if (inDark && rule instanceof CSSStyleRule && rule.selectorText === ":root") {
        for (const name of rule.style) if (name.startsWith("--")) tokens.push([name, rule.style.getPropertyValue(name)]);
      }
    }
  };
  for (const sheet of document.styleSheets) {
    try {
      visit(sheet.cssRules, false);
    } catch {
      // A sheet of another origin: not the wiki's.
    }
  }
  for (const [name, value] of tokens) {
    if (dark) host.style.setProperty(name, value);
    else host.style.removeProperty(name);
  }
  host.style.colorScheme = dark ? "dark" : "";
  return tokens.length > 0;
}

// Hover the first element the selector finds in the open editor's text, as
// a mouse resting on it: a mousemove at its middle, which CodeMirror's
// hover tooltips wait on. False when there is no such element.
function wiki_test_hover(selector) {
  const hosts = document.querySelectorAll(".editor-cm:not(:empty)");
  const element = hosts[hosts.length - 1]?.querySelector(selector);
  if (!element) return false;
  const box = element.getBoundingClientRect();
  const at = { bubbles: true, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 };
  element.dispatchEvent(new MouseEvent("mouseover", at));
  element.dispatchEvent(new MouseEvent("mousemove", at));
  return true;
}

// The contrast ratio (WCAG 2) of the text of the first element the
// selector finds in the open editor against what is drawn behind it: the
// element's computed colour on the first background, from the element up,
// that is not transparent, blended over the backgrounds under it. -1 when
// there is no such element. As JSON with the two colours, for the message
// of a failed test.
function wiki_test_contrast(selector) {
  const hosts = document.querySelectorAll(".editor-cm:not(:empty)");
  const element = hosts[hosts.length - 1]?.querySelector(selector);
  if (!element) return JSON.stringify({ ratio: -1 });
  const parse = (css) => {
    // Chromium writes a computed colour as rgb(), rgba() or, for one
    // mixed in another space, color(srgb r g b / a).
    const rgb = css.match(/^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/);
    if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3]), rgb[4] === undefined ? 1 : Number(rgb[4])];
    const srgb = css.match(/^color\(srgb ([\d.]+) ([\d.]+) ([\d.]+)(?: \/ ([\d.]+))?\)$/);
    if (srgb) return [Number(srgb[1]) * 255, Number(srgb[2]) * 255, Number(srgb[3]) * 255, srgb[4] === undefined ? 1 : Number(srgb[4])];
    return null;
  };
  const over = (top, under) => {
    const a = top[3];
    return [0, 1, 2].map((i) => top[i] * a + under[i] * (1 - a)).concat([1]);
  };
  // The backgrounds from the element up to the page, the nearest first,
  // blended from the page's white upwards.
  const layers = [];
  for (let node = element; node instanceof Element; node = node.parentElement) {
    const colour = parse(getComputedStyle(node).backgroundColor);
    if (colour && colour[3] > 0) layers.push(colour);
    if (colour && colour[3] === 1) break;
  }
  let background = [255, 255, 255, 1];
  for (const layer of layers.reverse()) background = over(layer, background);
  const text = parse(getComputedStyle(element).color) ?? [0, 0, 0, 1];
  const shown = over(text, background);
  const luminance = (c) => {
    const [r, g, b] = c.slice(0, 3).map((v) => {
      const s = v / 255;
      return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const [light, dark] = [luminance(shown), luminance(background)].sort((x, y) => y - x);
  const ratio = (light + 0.05) / (dark + 0.05);
  return JSON.stringify({ ratio, text: getComputedStyle(element).color, background: `rgb(${background.slice(0, 3).map(Math.round).join(", ")})` });
}
