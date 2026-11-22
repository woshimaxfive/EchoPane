"""Antialiased rounded surfaces for the Windows backdrop and ttk theme."""

import numpy as np


def bgr(color):
    return tuple(reversed(bytes.fromhex(color[1:])))


def rounded_pixels(width, height, radius, fill, border, *, background=None):
    """Return top-down premultiplied BGRA, or composite onto a known background."""
    fill_channels = bgr(fill)
    border_channels = bgr(border)
    pixels = np.empty((height, width, 4), dtype=np.uint8)
    pixels[:] = (*fill_channels, 255)
    edge = (*border_channels, 255)
    pixels[[0, -1], :] = edge
    pixels[:, [0, -1]] = edge

    radius = min(radius, width // 2, height // 2)
    if radius:
        offsets = radius - 0.5 - np.arange(radius, dtype=np.float32)
        distance = np.hypot.outer(offsets, offsets)
        outer = np.clip(radius + 0.5 - distance, 0, 1)
        inner = np.clip(radius - 0.5 - distance, 0, 1)
        color = inner[..., None] * fill_channels + (outer - inner)[..., None] * border_channels
        if background is not None:
            color += (1 - outer)[..., None] * bgr(background)
        corner = np.empty((radius, radius, 4), dtype=np.uint8)
        corner[..., :3] = np.rint(color).astype(np.uint8)
        corner[..., 3] = 255 if background is not None else np.rint(255 * outer).astype(np.uint8)
        pixels[:radius, :radius] = corner
        pixels[:radius, -radius:] = corner[:, ::-1]
        pixels[-radius:, :radius] = corner[::-1]
        pixels[-radius:, -radius:] = corner[::-1, ::-1]
    return pixels
