#!/usr/bin/env python3
"""Génère des fichiers 3D de test (aucune dépendance) dans le dossier donné en argument."""
import math, os, struct, sys, zipfile, zlib

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def sub(a, b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])

def grid_mesh(fn, nu, nv, wrap_u=True, wrap_v=False):
    """Maillage paramétrique -> (sommets, triangles, uv)."""
    verts, uvs, tris = [], [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            u, v = i / nu, j / nv
            verts.append(fn(u, v)); uvs.append((u, v))
    for j in range(nv):
        for i in range(nu):
            a = j*(nu+1)+i; b = a+1; c = a+(nu+1); d = c+1
            tris += [(a, c, b), (b, c, d)]
    return verts, tris, uvs

def sphere(u, v, r=20):
    th, ph = 2*math.pi*u, math.pi*v
    return (r*math.sin(ph)*math.cos(th), r*math.sin(ph)*math.sin(th), r*math.cos(ph))

def torus(u, v, R=20, r=7):
    a, b = 2*math.pi*u, 2*math.pi*v
    return ((R+r*math.cos(b))*math.cos(a), (R+r*math.cos(b))*math.sin(a), r*math.sin(b))

def vase(u, v):
    a = 2*math.pi*u
    z = 60*v
    r = 10 + 8*math.sin(v*math.pi*1.2) + 6*v*v - 4*v
    return (r*math.cos(a), r*math.sin(a), z)

def write_stl_binary(path, verts, tris):
    with open(path, 'wb') as f:
        f.write(b'View3D test'.ljust(80, b' '))
        f.write(struct.pack('<I', len(tris)))
        for t in tris:
            a, b, c = verts[t[0]], verts[t[1]], verts[t[2]]
            n = cross(sub(b, a), sub(c, a)); l = math.sqrt(sum(x*x for x in n)) or 1
            f.write(struct.pack('<3f', *(x/l for x in n)))
            for p in (a, b, c): f.write(struct.pack('<3f', *p))
            f.write(b'\0\0')

def write_stl_ascii(path, verts, tris, name='torus'):
    with open(path, 'w') as f:
        f.write(f'solid {name}\n')
        for t in tris:
            a, b, c = verts[t[0]], verts[t[1]], verts[t[2]]
            n = cross(sub(b, a), sub(c, a)); l = math.sqrt(sum(x*x for x in n)) or 1
            f.write(f'  facet normal {n[0]/l:e} {n[1]/l:e} {n[2]/l:e}\n    outer loop\n')
            for p in (a, b, c): f.write(f'      vertex {p[0]:e} {p[1]:e} {p[2]:e}\n')
            f.write('    endloop\n  endfacet\n')
        f.write(f'endsolid {name}\n')

# STL
v, t, _ = grid_mesh(vase, 64, 48)
write_stl_binary(f'{out}/vase_binaire.stl', v, t)
v, t, _ = grid_mesh(torus, 48, 24)
write_stl_ascii(f'{out}/tore_ascii.stl', v, t)

# Cube mécanique (arêtes vives) en STL binaire : vérifie que les angles restent nets
cv = [(x, y, z) for x in (-15, 15) for y in (-10, 10) for z in (-8, 8)]
def vid(x, y, z): return cv.index((x, y, z))
faces = []
for (axis, s) in [(0, -15), (0, 15), (1, -10), (1, 10), (2, -8), (2, 8)]:
    pts = [p for p in cv if p[axis] == s]
    pts.sort(key=lambda p: (p[(axis+1) % 3], p[(axis+2) % 3]))
    a, b, c, d = [cv.index(p) for p in pts]
    faces += [(a, b, c), (b, d, c)]
write_stl_binary(f'{out}/cube_arretes_vives.stl', cv, faces)

# OBJ avec matériaux colorés (2 parties) + normales calculées par l'app
v, t, uv = grid_mesh(sphere, 40, 20)
vt, tt, _ = grid_mesh(torus, 40, 20)
with open(f'{out}/personnage_couleurs.mtl', 'w') as f:
    f.write('newmtl rouge\nKd 0.85 0.15 0.15\n\nnewmtl bleu\nKd 0.15 0.35 0.9\n')
with open(f'{out}/personnage_couleurs.obj', 'w') as f:
    f.write('mtllib personnage_couleurs.mtl\no corps\n')
    for p in v: f.write(f'v {p[0]:.4f} {p[2]:.4f} {p[1]:.4f}\n')
    for p in vt: f.write(f'v {p[0]*0.9:.4f} {p[2]*0.9 + 28:.4f} {p[1]*0.9:.4f}\n')
    f.write('usemtl rouge\n')
    for a, b, c in t: f.write(f'f {a+1} {b+1} {c+1}\n')
    f.write('usemtl bleu\n')
    off = len(v)
    for a, b, c in tt: f.write(f'f {a+off+1} {b+off+1} {c+off+1}\n')

# OBJ texturé (damier) avec UV + normales + faces quad
def png(path, w, h, fn):
    raw = b''.join(b'\0' + bytes(c for x in range(w) for c in fn(x, y)) for y in range(h))
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
png(f'{out}/damier.png', 128, 128, lambda x, y: (230, 150, 40) if ((x//16) + (y//16)) % 2 else (40, 90, 200))
v, t, uv = grid_mesh(torus, 36, 18)
with open(f'{out}/tore_texture.mtl', 'w') as f: f.write('newmtl m\nKd 1 1 1\nmap_Kd damier.png\n')
with open(f'{out}/tore_texture.obj', 'w') as f:
    f.write('mtllib tore_texture.mtl\nusemtl m\n')
    for p in v: f.write(f'v {p[0]:.4f} {p[2]:.4f} {p[1]:.4f}\n')
    for p in uv: f.write(f'vt {p[0]*4:.4f} {p[1]*2:.4f}\n')
    for a, b, c in t: f.write(f'f {a+1}/{a+1} {b+1}/{b+1} {c+1}/{c+1}\n')

# PLY ASCII coloré + PLY binaire coloré
v, t, _ = grid_mesh(sphere, 36, 18)
def col(p): return tuple(max(0, min(255, int(127+127*c/28))) for c in p)
with open(f'{out}/sphere_ply_ascii.ply', 'w') as f:
    f.write(f'ply\nformat ascii 1.0\nelement vertex {len(v)}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face {len(t)}\nproperty list uchar int vertex_indices\nend_header\n')
    for p in v: f.write(f'{p[0]:.4f} {p[1]:.4f} {p[2]:.4f} {" ".join(map(str, col(p)))}\n')
    for a, b, c in t: f.write(f'3 {a} {b} {c}\n')
v, t, _ = grid_mesh(torus, 60, 30)
with open(f'{out}/tore_ply_binaire.ply', 'wb') as f:
    f.write(f'ply\nformat binary_little_endian 1.0\nelement vertex {len(v)}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face {len(t)}\nproperty list uchar int vertex_indices\nend_header\n'.encode())
    for p in v: f.write(struct.pack('<3f3B', *p, *col(p)))
    for a, b, c in t: f.write(struct.pack('<B3i', 3, a, b, c))

# 3MF (zip + XML) : un tore
v, t, _ = grid_mesh(torus, 48, 24)
verts = ''.join(f'<vertex x="{p[0]:.4f}" y="{p[1]:.4f}" z="{p[2]:.4f}"/>' for p in v)
tris = ''.join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in t)
model = f'<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="model"><mesh><vertices>{verts}</vertices><triangles>{tris}</triangles></mesh></object></resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 8"/></build></model>'
with zipfile.ZipFile(f'{out}/tore_impression.3mf', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
    z.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
    z.writestr('3D/3dmodel.model', model)

# USDA (texte) : une pyramide
with open(f'{out}/pyramide.usda', 'w') as f:
    f.write('''#usda 1.0
(
    defaultPrim = "Pyr"
    upAxis = "Y"
)
def Xform "Pyr"
{
    def Mesh "mesh"
    {
        int[] faceVertexCounts = [3, 3, 3, 3, 4]
        int[] faceVertexIndices = [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4, 3, 2, 1, 0]
        point3f[] points = [(-1, 0, -1), (1, 0, -1), (1, 0, 1), (-1, 0, 1), (0, 1.6, 0)]
        color3f[] primvars:displayColor = [(0.9, 0.5, 0.2)]
    }
}
''')

# Fichier corrompu
open(f'{out}/corrompu.stl', 'wb').write(b'ceci n est pas un fichier 3D' * 3)
print('ok', sorted(os.listdir(out)))
