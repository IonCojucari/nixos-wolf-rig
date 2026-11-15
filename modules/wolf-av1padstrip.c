/* av1padstrip: drop OBU_PADDING from an AV1 OBU stream.
 *
 * AMD's VA-API encoder in CBR fills every frame up to the target bitrate
 * with padding OBUs. A decoder ignores them, so they are pure bandwidth.
 * This element removes them and leaves every other byte untouched; the
 * encoder keeps its CBR rate control and never learns the difference.
 *
 * Input must be "obu-stream" (every OBU carries its size field), which is
 * what vaav1enc and av1parse produce. A buffer that does not parse cleanly
 * is passed through unchanged.
 *
 * Build (inside the Wolf image, so it links against that GStreamer):
 *   gcc -shared -fPIC -O2 gstav1padstrip.c -o libgstav1padstrip.so \
 *       $(pkg-config --cflags --libs gstreamer-base-1.0)
 */
#include <string.h>
#include <gst/gst.h>
#include <gst/base/gstbasetransform.h>

#ifndef PACKAGE
#define PACKAGE "av1padstrip"
#endif

#define OBU_PADDING 15

#define GST_TYPE_AV1_PAD_STRIP (gst_av1_pad_strip_get_type ())
G_DECLARE_FINAL_TYPE (GstAv1PadStrip, gst_av1_pad_strip, GST, AV1_PAD_STRIP,
    GstBaseTransform)

struct _GstAv1PadStrip
{
  GstBaseTransform parent;
};

G_DEFINE_TYPE (GstAv1PadStrip, gst_av1_pad_strip, GST_TYPE_BASE_TRANSFORM)

static GstStaticPadTemplate sink_template =
GST_STATIC_PAD_TEMPLATE ("sink", GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS ("video/x-av1"));

static GstStaticPadTemplate src_template =
GST_STATIC_PAD_TEMPLATE ("src", GST_PAD_SRC, GST_PAD_ALWAYS,
    GST_STATIC_CAPS ("video/x-av1"));

/* Length of the OBU starting at data[0], header and size field included.
 * Returns 0 when it cannot be determined. */
static gsize
obu_length (const guint8 * data, gsize avail, guint * type)
{
  gsize pos, payload = 0;
  guint shift = 0;
  guint8 hdr;

  if (avail < 2)
    return 0;
  hdr = data[0];
  if (hdr & 0x80)               /* forbidden bit */
    return 0;
  if (!(hdr & 0x02))            /* no size field: not an obu-stream */
    return 0;
  *type = (hdr >> 3) & 0x0f;
  pos = 1 + ((hdr >> 2) & 1);   /* optional extension byte */

  for (;;) {                    /* leb128 */
    guint8 b;
    if (pos >= avail || shift > 28)
      return 0;
    b = data[pos++];
    payload |= ((gsize) (b & 0x7f)) << shift;
    shift += 7;
    if (!(b & 0x80))
      break;
  }
  if (payload > avail - pos)
    return 0;
  return pos + payload;
}

static GstFlowReturn
gst_av1_pad_strip_transform_ip (GstBaseTransform * trans, GstBuffer * buf)
{
  GstMapInfo map;
  gsize in = 0, out = 0;
  gboolean ok = TRUE, found = FALSE;

  /* First pass, read-only: is there anything to remove, and does the
   * whole buffer parse? */
  if (!gst_buffer_map (buf, &map, GST_MAP_READ))
    return GST_FLOW_OK;
  while (in < map.size) {
    guint type = 0;
    gsize len = obu_length (map.data + in, map.size - in, &type);
    if (len == 0) {
      ok = FALSE;
      break;
    }
    if (type == OBU_PADDING)
      found = TRUE;
    in += len;
  }
  gst_buffer_unmap (buf, &map);
  if (!ok || !found)
    return GST_FLOW_OK;

  /* Second pass: compact in place. */
  if (!gst_buffer_map (buf, &map, GST_MAP_READWRITE))
    return GST_FLOW_OK;
  in = 0;
  while (in < map.size) {
    guint type = 0;
    gsize len = obu_length (map.data + in, map.size - in, &type);
    if (type != OBU_PADDING) {
      if (out != in)
        memmove (map.data + out, map.data + in, len);
      out += len;
    }
    in += len;
  }
  gst_buffer_unmap (buf, &map);
  gst_buffer_set_size (buf, out);
  return GST_FLOW_OK;
}

static void
gst_av1_pad_strip_class_init (GstAv1PadStripClass * klass)
{
  GstElementClass *element_class = GST_ELEMENT_CLASS (klass);
  GstBaseTransformClass *trans_class = GST_BASE_TRANSFORM_CLASS (klass);

  gst_element_class_add_static_pad_template (element_class, &sink_template);
  gst_element_class_add_static_pad_template (element_class, &src_template);
  gst_element_class_set_static_metadata (element_class,
      "AV1 padding stripper", "Codec/Filter/Video",
      "Removes OBU_PADDING from an AV1 OBU stream", "wolf-rig");

  trans_class->transform_ip = gst_av1_pad_strip_transform_ip;
}

static void
gst_av1_pad_strip_init (GstAv1PadStrip * self)
{
  /* Never passthrough: transform_ip must always get a writable buffer. */
  gst_base_transform_set_in_place (GST_BASE_TRANSFORM (self), TRUE);
  gst_base_transform_set_passthrough (GST_BASE_TRANSFORM (self), FALSE);
}

static gboolean
plugin_init (GstPlugin * plugin)
{
  return gst_element_register (plugin, "av1padstrip", GST_RANK_NONE,
      GST_TYPE_AV1_PAD_STRIP);
}

GST_PLUGIN_DEFINE (GST_VERSION_MAJOR, GST_VERSION_MINOR, av1padstrip,
    "Removes OBU_PADDING from an AV1 OBU stream", plugin_init, "1.0", "MIT/X11",
    "wolf-rig", "https://github.com/games-on-whales/wolf")
