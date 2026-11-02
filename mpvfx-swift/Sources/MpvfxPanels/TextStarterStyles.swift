//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation
import MpvfxShared

/// The eight text styles that ship with the app (issue #284), listed in the Style menu after the user's own and copied
/// into a project the first time one is used. They use only the generic "Sans" and "Monospace" families, which every
/// platform resolves to a font the system ships, so no font file is bundled. Every style sets its text against an
/// outline or a plate, so it reads on a white, a black and a mid-grey frame.
public enum TextStarterStyles {
    /// The set as JSON. The `copyright` lines are part of the document, as the block is part of every source file.
    public static let json = """
    {
      "copyright": [
        "Copyright (c) 2026 Arshiya Rahgozar.",
        "Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0)",
        "or the MIT license (LICENSE-MIT or http://opensource.org/licenses/MIT), at your option.",
        "SPDX-License-Identifier: MIT OR Apache-2.0"
      ],
      "version": 1,
      "styles": [
        {"v": 1, "kind": "text-style", "id": "starter:lower-third", "name": "Lower third",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 36, "fontWeight": 700, "color": "#ffffff", "align": "left",
                  "look": {"v": 1, "plate": {"mode": "block", "paddingX": 18, "paddingY": 10, "radius": 6, "color": "#000000cc"}}}},
        {"v": 1, "kind": "text-style", "id": "starter:bold-title", "name": "Bold title",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 84, "fontWeight": 800, "color": "#ffffff", "align": "center",
                  "look": {"v": 1, "outlines": [{"width": 4, "color": "#000000"}],
                           "shadow": {"x": 0, "y": 4, "blur": 8, "color": "#000000b3"}}}},
        {"v": 1, "kind": "text-style", "id": "starter:subtitle-plate", "name": "Subtitle plate",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 30, "fontWeight": 500, "color": "#ffffff", "align": "center",
                  "look": {"v": 1, "plate": {"paddingX": 12, "paddingY": 6, "radius": 4, "color": "#000000d9"}}}},
        {"v": 1, "kind": "text-style", "id": "starter:quote", "name": "Quote",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 48, "fontWeight": 400, "color": "#ffffff", "align": "center",
                  "fontStyle": "italic", "lineHeight": 1.3,
                  "look": {"v": 1, "outlines": [{"width": 2, "color": "#000000"}]}}},
        {"v": 1, "kind": "text-style", "id": "starter:label", "name": "Label",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 24, "fontWeight": 600, "color": "#ffffff", "align": "left",
                  "letterSpacing": 2, "textTransform": "uppercase",
                  "look": {"v": 1, "plate": {"paddingX": 10, "paddingY": 5, "radius": 3, "color": "#1a1a1af2"}}}},
        {"v": 1, "kind": "text-style", "id": "starter:outline-title", "name": "Outline title",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 88, "fontWeight": 800, "color": "#ffd60a", "align": "center",
                  "textTransform": "uppercase",
                  "look": {"v": 1, "outlines": [{"width": 6, "color": "#000000"}]}}},
        {"v": 1, "kind": "text-style", "id": "starter:soft-shadow", "name": "Soft shadow",
         "text": {"content": "", "fontFamily": "Sans", "fontSize": 56, "fontWeight": 600, "color": "#ffffff", "align": "center",
                  "look": {"v": 1, "outlines": [{"width": 1, "color": "#000000"}],
                           "shadow": {"x": 0, "y": 3, "blur": 12, "color": "#000000cc"}}}},
        {"v": 1, "kind": "text-style", "id": "starter:mono-caption", "name": "Mono caption",
         "text": {"content": "", "fontFamily": "Monospace", "fontSize": 28, "fontWeight": 400, "color": "#ffffff", "align": "left",
                  "look": {"v": 1, "plate": {"mode": "block", "paddingX": 10, "paddingY": 4, "radius": 2, "color": "#000000cc"}}}}
      ]
    }
    """

    /// The eight styles, in menu order.
    public static let styles: [NativeTextStyle] = {
        struct Document: Decodable { var styles: [NativeTextStyle] }
        guard let document = try? JSONDecoder().decode(Document.self, from: Data(json.utf8)) else { return [] }
        return document.styles
    }()
}
