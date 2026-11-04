// The avatar's crop (WP5.55 of docs/PLAN.md): Cropper.js's elements, put in
// an element the account's avatar dialog (Wiki.App.View.Avatar) holds by ref
// and never looks inside, with the picture the user chose. A square
// selection, shown round, picks the part of the picture to keep; the result
// is that part as a PNG of 256 by 256 pixels, which the application uploads.
//
// web/bundle.sh bundles this file, with Cropper.js, into islands/avatar.js,
// which islands.js imports the first time the dialog opens, so that no page
// pays for the cropper until someone crops a picture. Importing Cropper.js
// defines its elements (cropper-canvas, cropper-image, cropper-selection
// and the rest); this module only puts them in place and reads the result.
import "cropperjs";

// The size of the picture uploaded, in pixels: plenty for an avatar shown a
// few dozen pixels wide, and small enough to stay far under the server's
// limit of 1 MB.
const SIZE = 256;

const element = (name, attributes) => {
  const made = document.createElement(name);
  for (const [key, value] of Object.entries(attributes)) made.setAttribute(key, value);
  return made;
};

// Put the cropper in `host`, on the picture in `file` (a File or a Blob),
// in place of whatever was there. The host then carries `wikiAvatar`, with
// `result()`, the crop as PNG bytes (a Promise of a Uint8Array, or of null
// when there is none), and `destroy()`, which lets the picture go.
export const crop = (host, file) => {
  host.wikiAvatar?.destroy();
  const url = URL.createObjectURL(file);
  // The canvas is a square the page's CSS sizes; its checked background
  // shows where the picture is not. The picture starts fitted whole inside
  // it ("contain"), centred, so that nothing of it is cut off before the
  // user chooses; the wheel zooms it by scale-step a notch.
  const canvas = element("cropper-canvas", { background: "", "scale-step": "0.1" });
  const image = element("cropper-image", { src: url, alt: "The picture to crop", "initial-center-size": "contain", translatable: "", scalable: "" });
  const selection = element("cropper-selection", { "aspect-ratio": "1", "initial-coverage": "0.8", movable: "", resizable: "", outlined: "" });
  selection.append(
    element("cropper-handle", { action: "move", "theme-color": "rgba(255, 255, 255, 0.35)" }),
    ...["ne", "nw", "se", "sw"].map((corner) => element("cropper-handle", { action: `${corner}-resize` })),
  );
  canvas.append(image, element("cropper-handle", { action: "select", plain: "" }), selection);
  host.replaceChildren(canvas);
  host.wikiAvatar = {
    result: async () => {
      const cropped = await selection.$toCanvas({ width: SIZE, height: SIZE });
      const blob = await new Promise((resolve) => cropped.toBlob(resolve, "image/png"));
      return blob === null ? null : new Uint8Array(await blob.arrayBuffer());
    },
    destroy: () => {
      URL.revokeObjectURL(url);
      host.replaceChildren();
      delete host.wikiAvatar;
    },
  };
};
