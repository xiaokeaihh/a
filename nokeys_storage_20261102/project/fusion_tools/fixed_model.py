"""Independent integer pixel reference for the adaptive RGB565 pipeline."""
import numpy as np


def coefficients():
    t = np.arange(256) / 256
    a = -0.5
    w0 = ((a*(t+1)-5*a)*(t+1)+8*a)*(t+1)-4*a
    w1 = ((a+2)*t-(a+3))*t*t+1
    w2 = ((a+2)*(1-t)-(a+3))*(1-t)**2+1
    weights = np.stack([w0, w1, w2, 1-w0-w1-w2], axis=1)
    result = np.floor(weights*4096 + 0.5).astype(np.int64)
    result[:, 1] += 4096-result.sum(axis=1)
    return result


def smooth(values, start, end):
    t = np.clip((values-start)/(end-start), 0, 1)
    return t*t*(3-2*t)


def detail_table():
    return np.floor(smooth(np.arange(128)/4, 12, 28)*256+0.5).astype(np.int64)


def unpack_rgb(pixels):
    return np.stack([pixels >> 11, (pixels >> 5) & 63, pixels & 31], axis=-1).astype(np.int64)


def pack_rgb(channels):
    return (channels[..., 0] << 11) | (channels[..., 1] << 5) | channels[..., 2]


def adaptive_pixels(windows, fx, fy, radial_blend, inside=None):
    """windows[...,4,4] contains floor-1..floor+2, row major; one final round."""
    colors = unpack_rgb(windows)
    central = colors[..., 1:3, 1:3, :]
    lower, upper = central.min(axis=(-3, -2)), central.max(axis=(-3, -2))
    luma_q2 = central[..., 0]*10+central[..., 1]*9+central[..., 2]*4
    contrast = luma_q2.max(axis=(-2, -1))-luma_q2.min(axis=(-2, -1))
    gate = detail_table()[np.minimum(contrast, 127)]
    alpha = (radial_blend*gate+128) >> 8
    wx, wy = coefficients()[fx], coefficients()[fy]
    horizontal_q12 = np.sum(colors*wx[..., None, :, None], axis=-2)
    horizontal_q8 = (horizontal_q12+8) >> 4
    cubic_q20 = np.sum(horizontal_q8*wy[..., :, None], axis=-2)
    cubic_q20 = np.clip(cubic_q20, lower << 20, upper << 20)
    xf, yf = fx[..., None], fy[..., None]
    top = central[..., 0, 0, :]*(256-xf)+central[..., 0, 1, :]*xf
    bottom = central[..., 1, 0, :]*(256-xf)+central[..., 1, 1, :]*xf
    linear_q20 = (top*(256-yf)+bottom*yf) << 4
    output = (linear_q20*256+(cubic_q20-linear_q20)*alpha[..., None]+(1 << 27)) >> 28
    output = np.clip(output, 0, [31, 63, 31])
    packed = pack_rgb(output)
    if inside is not None:
        packed = np.where(inside, packed, 0)
    return packed, alpha


def pattern_pixels(x, y):
    index = y*1280+x
    return ((index*251) ^ (index >> 3) ^ 0x5a96) & 65535


def pattern_windows(xq, yq):
    x, y = xq >> 8, yq >> 8
    return np.stack([pattern_pixels(x+dx, y+dy) for dy in (-1, 0, 1, 2)
                     for dx in (-1, 0, 1, 2)], axis=-1).reshape(*xq.shape, 4, 4)
