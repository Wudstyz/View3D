# Notices tierces / Third-party notices

## Dépendances / Dependencies

**View 3D n'embarque aucun code tiers, aucune bibliothèque et aucun runtime externe.**
**View 3D bundles no third-party code, library or external runtime.**

L'application utilise uniquement les frameworks fournis par macOS (© Apple Inc.), liés dynamiquement et non redistribués :
The app only uses frameworks provided by macOS (© Apple Inc.), dynamically linked and not redistributed:

| Framework | Usage |
|---|---|
| SwiftUI, AppKit | Interface / User interface |
| SceneKit, Metal | Rendu 3D et vignettes / 3D rendering and thumbnails |
| Model I/O | Lecture de formats 3D (USD, Alembic, Collada…) / Reading some 3D formats |
| Compression | Décompression des archives 3MF / Unzipping 3MF archives |
| Foundation, UniformTypeIdentifiers | Fichiers, types de fichiers / Files, file types |

Les lecteurs STL, OBJ, PLY et 3MF sont écrits pour ce projet (`Sources/Loaders.swift`).
The STL, OBJ, PLY and 3MF readers are written for this project (`Sources/Loaders.swift`).

## Outils de construction / Build tools

Xcode / Swift (Apple) — uniquement pour construire l'app depuis les sources, non inclus dans l'app.
Xcode / Swift (Apple) — only needed to build from source, not included in the app.

## Marques / Trademarks

Apple, macOS, Mac, Finder, SceneKit, Metal, Xcode et Swift sont des marques d'Apple Inc. USD/USDZ est un format de Pixar/Apple ; Alembic est un projet de Sony Pictures Imageworks et Lucasfilm ; Collada est une marque de Khronos Group ; 3MF est un format du 3MF Consortium ; GitHub est une marque de GitHub, Inc. Toutes les marques citées appartiennent à leurs propriétaires respectifs. **View 3D est un projet indépendant, non affilié à ces organisations.**

Apple, macOS, Mac, Finder, SceneKit, Metal, Xcode and Swift are trademarks of Apple Inc. USD/USDZ is a format from Pixar/Apple; Alembic is a project of Sony Pictures Imageworks and Lucasfilm; Collada is a trademark of the Khronos Group; 3MF is a format of the 3MF Consortium; GitHub is a trademark of GitHub, Inc. All mentioned trademarks belong to their respective owners. **View 3D is an independent project and is not affiliated with these organizations.**

## Icône / Icon

L'icône est dessinée pour ce projet (`Tools/make_icon.swift`) et publiée sous la même licence MIT.
The icon is drawn for this project (`Tools/make_icon.swift`) and released under the same MIT license.
