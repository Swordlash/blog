// What a page shown as slides (Wiki.App.View.Slides) asks of the browser
// beyond Halogen's DOM: which of its keys a keydown is, where a touch
// started and ended, the browser's full screen, focus, and printing.

// The command a keydown is for, if it is one of the slides' keys: "next",
// "previous", "first", "last", "choose" (Enter: the slide picked in the
// overview, or the next), "fullscreen", "notes", "overview", "leave"
// (Escape), or "" for any other key, which the browser keeps. Keys with Ctrl,
// Alt or Cmd held are the browser's (Ctrl+P prints, Alt+Left goes back), and
// so is a key typed into a field, and Space or Enter on a button or a link,
// which press it.
function wiki_slides_key(event) {
  if (typeof event.key !== "string") return "";
  if (event.ctrlKey || event.metaKey || event.altKey) return "";
  const target = event.target;
  if (target instanceof Element && target.closest("input:not([type=checkbox]), textarea, select, [contenteditable]")) return "";
  const pressable = target instanceof Element && target.closest("button, a[href], summary, input") !== null;
  switch (event.key) {
    case "ArrowRight":
    case "ArrowDown":
    case "PageDown":
      return "next";
    case " ":
      if (pressable) return "";
      return event.shiftKey ? "previous" : "next";
    case "Enter":
      if (pressable) return "";
      return event.shiftKey ? "previous" : "choose";
    case "ArrowLeft":
    case "ArrowUp":
    case "PageUp":
    case "Backspace":
      return "previous";
    case "Home":
      return "first";
    case "End":
      return "last";
    case "f":
    case "F":
      return "fullscreen";
    case "n":
    case "N":
    case "s":
    case "S":
      return "notes";
    case "o":
    case "O":
      return "overview";
    case "Escape":
      return "leave";
    default:
      return "";
  }
}

// Where a touch event's first changed touch is across the screen, in CSS
// pixels, or NaN for an event that has none.
function wiki_slides_touch_x(event) {
  const touch = event.changedTouches?.[0];
  return touch === undefined ? NaN : touch.clientX;
}

function wiki_slides_touch_y(event) {
  const touch = event.changedTouches?.[0];
  return touch === undefined ? NaN : touch.clientY;
}

// The element full screen, or the page back from full screen if anything
// is. A browser that will not (no user gesture, or not allowed in a frame)
// rejects the promise, which is ignored: the slides fill the window anyway.
function wiki_slides_toggle_fullscreen(element) {
  if (document.fullscreenElement) {
    document.exitFullscreen?.().catch(() => {});
  } else {
    element.requestFullscreen?.().catch(() => {});
  }
}

// Leave full screen, if the page is.
function wiki_slides_exit_fullscreen() {
  if (document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
}

// Focus the element without scrolling, so that the slides' keys reach it.
function wiki_slides_focus(element) {
  element.focus({ preventScroll: true });
}

// The browser's print dialog, from which a deck is saved as a PDF.
function wiki_slides_print() {
  window.print();
}
