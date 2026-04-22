// XmlNavigator — macOS port
//
// Shows the structure of an XML file in a tree view and allows fast
// navigation by clicking nodes. Port of the Windows XmlNavigator plugin
// originally written in C# by strike-a-light (archived repo at
// github.com/chcg/XmlNavigator). This macOS port rewrites the
// plugin in Objective-C++ using AppKit and a hand-rolled XML tokenizer
// that gives precise byte offsets for each element's start/end and
// content start/end. Those offsets drive the six context-menu actions:
// Go To Node Start / End, Go To Content Start / End, Select Node, Select
// Content. Clicking a tree row jumps the Scintilla caret to the node's
// opening tag.
//
// The tokenizer is intentionally permissive — it doesn't validate XML,
// just locates tag boundaries. That lets the navigator work on
// ill-formed documents the user is in the middle of editing.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>
#include <memory>
#include <algorithm>

// ---------------------------------------------------------------------------
// Plugin identification
// ---------------------------------------------------------------------------
static const char *PLUGIN_NAME = "XML Navigator";
static const int NB_FUNC = 2;
static FuncItem funcItem[NB_FUNC];
NppData nppData;

enum FuncIdx {
    IdxShowNavigator = 0,
    IdxAbout
};

// Forward decls
@class NavigatorPanel;
static NavigatorPanel *g_panel = nil;
static void xmlNavigatorShowPanel(void);
static void xmlNavigatorHidePanel(void);
static BOOL xmlNavigatorPanelIsShown(void);

// ---------------------------------------------------------------------------
// Scintilla / NPP helpers
// ---------------------------------------------------------------------------
static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

static NppHandle currentScintilla() {
    int which = -1;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? nppData._scintillaSecondHandle
                        : nppData._scintillaMainHandle;
}

static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(currentScintilla(), msg, w, l);
}

// Read the full current document text as a std::string.
static std::string currentDocumentText() {
    NppHandle h = currentScintilla();
    intptr_t length = nppData._sendMessage(h, SCI_GETLENGTH, 0, 0);
    if (length <= 0) return std::string();
    std::string buf;
    buf.resize((size_t)length);
    nppData._sendMessage(h, SCI_GETTEXT, (uintptr_t)(length + 1), (intptr_t)buf.data());
    // SCI_GETTEXT writes a NUL terminator; we sized buf to `length` so no trim needed.
    return buf;
}

// ---------------------------------------------------------------------------
// XML tree model
// ---------------------------------------------------------------------------

// Plain ObjC class so NSOutlineView can use identity comparison and we can
// hang weak references off attribute/comment fields.
@interface XNNode : NSObject
@property(nonatomic, copy)   NSString *name;
@property(nonatomic, copy)   NSString *localName;
@property(nonatomic, copy)   NSString *displayName;
@property(nonatomic, strong) NSArray<NSDictionary *> *attributes; // {name, value}
@property(nonatomic, copy)   NSString *comment;
@property(nonatomic, assign) intptr_t nodeStart;     // position of '<' of opening tag
@property(nonatomic, assign) intptr_t nodeEnd;       // position AFTER '>' of closing tag (or '/>')
@property(nonatomic, assign) intptr_t contentStart;  // position after '>' of opening tag
@property(nonatomic, assign) intptr_t contentEnd;    // position of '<' of closing tag (or -1 if empty)
@property(nonatomic, assign) BOOL isEmpty;           // self-closing <tag/> OR <tag></tag> with no intervening chars
@property(nonatomic, assign) NSInteger depth;
@property(nonatomic, strong) NSMutableArray<XNNode *> *children;
// `weak` is safe under ARC: parent always outlives its children (they're
// owned up the chain by `children` arrays), but weak also auto-nils if a
// subtree is detached.
@property(nonatomic, weak)   XNNode *parent;
@end

@implementation XNNode
- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeStart = _nodeEnd = _contentStart = _contentEnd = -1;
        _children = [NSMutableArray array];
    }
    return self;
}

- (NSString *)description { return self.displayName ?: self.localName ?: @"(unnamed)"; }

// Checks whether the display name contains every token in filterItems (case-insensitive).
// This matches the Windows impl: all tokens must match, order-independent.
- (BOOL)nameMatchesFilter:(NSArray<NSString *> *)filterItems {
    if (filterItems.count == 0) return YES;
    NSString *haystack = self.displayName ?: @"";
    for (NSString *token in filterItems) {
        if (token.length == 0) continue;
        if ([haystack rangeOfString:token options:NSCaseInsensitiveSearch].location == NSNotFound)
            return NO;
    }
    return YES;
}

// A subtree matches if this node OR any descendant matches.
- (BOOL)subtreeMatchesFilter:(NSArray<NSString *> *)filterItems {
    if (filterItems.count == 0) return YES;
    if ([self nameMatchesFilter:filterItems]) return YES;
    for (XNNode *c in self.children)
        if ([c subtreeMatchesFilter:filterItems]) return YES;
    return NO;
}
@end

// ---------------------------------------------------------------------------
// XNOutlineView — hides the native disclosure triangle.
//
// NSOutlineView always draws a triangle in its outlineColumn for
// expandable items. We want to replace that with a +/- button drawn by
// our own cell view (matching the Search Results Panel markers). The
// documented way to suppress the native triangle is to override
// -frameOfOutlineCellAtRow: and return NSZeroRect.
// ---------------------------------------------------------------------------
@interface XNOutlineView : NSOutlineView
@end

@implementation XNOutlineView
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row { return NSZeroRect; }
@end

// ---------------------------------------------------------------------------
// XNDiscView — custom-drawn +/- disclosure indicator.
//
// NSButton brings its own bezel minimum sizes and padding that puff the
// rendered control well past any explicit width/height constraints — fine
// for a chrome-bearing push button, but wrong for the tight box markers
// used in the Search Results Panel (which draws Scintilla SC_MARK_BOXPLUS
// at ~9–10px). Rather than fight NSButton's intrinsic sizing, we draw a
// 1px-bordered box with a +/- glyph inside. Click handling is delegated
// to a block so cells can be recycled without retarget plumbing.
// ---------------------------------------------------------------------------
@interface XNDiscView : NSView
@property(nonatomic, assign) BOOL expanded;   // YES → draw "−", NO → draw "+"
@property(nonatomic, copy)   void (^onClick)(void);
@end

@implementation XNDiscView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    NSRect b = NSInsetRect(self.bounds, 0.5, 0.5);
    // Box border
    [[NSColor secondaryLabelColor] setStroke];
    NSBezierPath *frame = [NSBezierPath bezierPathWithRect:b];
    frame.lineWidth = 1.0;
    [frame stroke];
    // Glyph lines: horizontal always; vertical only when collapsed ("+").
    [[NSColor labelColor] setStroke];
    NSBezierPath *g = [NSBezierPath bezierPath];
    g.lineWidth = 1.0;
    CGFloat cx = floor(NSMidX(b)) + 0.5;
    CGFloat cy = floor(NSMidY(b)) + 0.5;
    CGFloat arm = floor(NSWidth(b) * 0.25);  // 25% half-width → consistent across sizes
    if (arm < 2) arm = 2;
    [g moveToPoint:NSMakePoint(cx - arm, cy)];
    [g lineToPoint:NSMakePoint(cx + arm, cy)];
    if (!self.expanded) {
        [g moveToPoint:NSMakePoint(cx, cy - arm)];
        [g lineToPoint:NSMakePoint(cx, cy + arm)];
    }
    [g stroke];
}
- (void)mouseDown:(NSEvent *)event {
    // Swallow the event so NSOutlineView doesn't interpret it as a row
    // selection/click (which would double-fire navigation alongside the
    // expand/collapse we're about to do).
    if (self.onClick) self.onClick();
}
@end

// ---------------------------------------------------------------------------
// XNCellView — row view: disclosure box + label.
//
// Leaf rows hide the disclosure view but keep the layout slot so labels
// across expandable and leaf rows line up at the same indent level.
// ---------------------------------------------------------------------------
@interface XNCellView : NSTableCellView
@property(nonatomic, strong) XNDiscView *discButton;
@end

@implementation XNCellView
@end

// ---------------------------------------------------------------------------
// XML tokenizer (hand-rolled, permissive)
//
// The parser scans UTF-8 bytes and emits open / close / self-closing events
// with byte offsets into the input. It skips comments, CDATA, PIs, DOCTYPE
// declarations. It tolerates malformed XML: if a closing tag doesn't match
// the expected element, we pop anyway so the tree doesn't runaway. That's
// the right UX for a document the user is still typing.
//
// Position semantics (match the Windows XmlParser.cs):
//   - nodeStart      = position of the '<' at the start of the opening tag
//   - contentStart   = position right after the '>' of the opening tag
//   - contentEnd     = position of the '<' of the closing tag
//   - nodeEnd        = position right after the '>' of the closing tag
//                       (for self-closing <tag/> this is after the '>')
// ---------------------------------------------------------------------------

namespace xmlscan {

struct ParseResult {
    // `__strong` required under ARC for ObjC pointers in C++ structs —
    // otherwise ARC can't determine ownership and the compiler errors out.
    __strong XNNode *root;      // root node or nil
    std::string errorMessage;   // empty on success
};

// Return true if ch could start a valid XML name character.
static inline bool isNameStart(unsigned char ch) {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
           ch == '_' || ch == ':' || ch >= 0x80;
}
static inline bool isNameChar(unsigned char ch) {
    return isNameStart(ch) || (ch >= '0' && ch <= '9') ||
           ch == '-' || ch == '.';
}

// Skip whitespace. Returns updated pos.
static size_t skipWS(const std::string &src, size_t pos) {
    while (pos < src.size()) {
        unsigned char c = (unsigned char)src[pos];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') ++pos;
        else break;
    }
    return pos;
}

// Read an XML name starting at pos. Returns a std::string and advances pos.
static std::string readName(const std::string &src, size_t &pos) {
    size_t start = pos;
    if (pos >= src.size() || !isNameStart((unsigned char)src[pos])) return std::string();
    ++pos;
    while (pos < src.size() && isNameChar((unsigned char)src[pos])) ++pos;
    return src.substr(start, pos - start);
}

// Read an attribute value starting at the opening quote. Returns the value
// (unescaped as a bonus: we decode &amp; &lt; &gt; &quot; &apos; for display).
static std::string readAttributeValue(const std::string &src, size_t &pos) {
    if (pos >= src.size()) return std::string();
    char quote = src[pos];
    if (quote != '"' && quote != '\'') return std::string();
    ++pos;  // skip opening quote
    std::string out;
    while (pos < src.size() && src[pos] != quote) {
        if (src[pos] == '&') {
            // Entity decode — cheap and local; we only decode the 5 builtins.
            size_t semi = src.find(';', pos);
            if (semi != std::string::npos && semi - pos <= 8) {
                std::string ent = src.substr(pos + 1, semi - pos - 1);
                if      (ent == "amp")  { out += '&';  pos = semi + 1; continue; }
                else if (ent == "lt")   { out += '<';  pos = semi + 1; continue; }
                else if (ent == "gt")   { out += '>';  pos = semi + 1; continue; }
                else if (ent == "quot") { out += '"';  pos = semi + 1; continue; }
                else if (ent == "apos") { out += '\''; pos = semi + 1; continue; }
            }
        }
        out += src[pos++];
    }
    if (pos < src.size() && src[pos] == quote) ++pos;  // skip closing quote
    return out;
}

// Scan past a '<!-- -->' comment. pos points at the '<'. Advances pos past '-->'.
// Returns the comment body if wanted.
static std::string readComment(const std::string &src, size_t &pos) {
    // pos is at '<'. Caller ensured we have '<!--'.
    pos += 4;
    size_t start = pos;
    size_t end = src.find("-->", pos);
    std::string body;
    if (end == std::string::npos) {
        pos = src.size();
    } else {
        body = src.substr(start, end - start);
        pos = end + 3;
    }
    return body;
}

// Skip '<![CDATA[ ... ]]>'. pos at '<'.
static void skipCDATA(const std::string &src, size_t &pos) {
    pos += 9;  // "<![CDATA["
    size_t end = src.find("]]>", pos);
    if (end == std::string::npos) pos = src.size();
    else pos = end + 3;
}

// Skip a processing instruction '<? ... ?>'. pos at '<'.
static void skipPI(const std::string &src, size_t &pos) {
    pos += 2;  // "<?"
    size_t end = src.find("?>", pos);
    if (end == std::string::npos) pos = src.size();
    else pos = end + 2;
}

// Skip a DOCTYPE or other markup decl: '<! ... >' with possible nested '[...]'.
// pos at '<'.
static void skipDoctype(const std::string &src, size_t &pos) {
    pos += 2;  // "<!"
    int bracketDepth = 0;
    while (pos < src.size()) {
        char c = src[pos];
        if (c == '[') ++bracketDepth;
        else if (c == ']') --bracketDepth;
        else if (c == '>' && bracketDepth <= 0) { ++pos; return; }
        ++pos;
    }
}

// Main parse. Produces a single root XNNode. If the document has multiple
// top-level elements (unusual but possible in XML fragments), only the first
// becomes root; subsequent siblings are appended as additional top-level
// children for display purposes — matching the tree shape users expect when
// editing a fragment.
static ParseResult parse(const std::string &src) {
    ParseResult result = { nil, std::string() };

    XNNode *synthesizedRoot = nil;  // used only if we find multiple top-level
    XNNode *root = nil;
    XNNode *current = nil;
    NSString *pendingComment = nil;  // attached to the next element we open

    size_t pos = 0;
    const size_t N = src.size();

    while (pos < N) {
        if (src[pos] != '<') { ++pos; continue; }

        // Various '<'-prefixed forms
        if (pos + 3 < N && src[pos + 1] == '!' && src[pos + 2] == '-' && src[pos + 3] == '-') {
            std::string body = readComment(src, pos);
            pendingComment = [NSString stringWithUTF8String:body.c_str()];
            continue;
        }
        if (pos + 8 < N && src.compare(pos, 9, "<![CDATA[") == 0) {
            skipCDATA(src, pos);
            continue;
        }
        if (pos + 1 < N && src[pos + 1] == '?') {
            skipPI(src, pos);
            continue;
        }
        if (pos + 1 < N && src[pos + 1] == '!') {
            skipDoctype(src, pos);
            continue;
        }

        // End tag?
        if (pos + 1 < N && src[pos + 1] == '/') {
            intptr_t tagStart = (intptr_t)pos;
            pos += 2;  // skip '</'
            std::string name = readName(src, pos);
            pos = skipWS(src, pos);
            if (pos < N && src[pos] == '>') ++pos;
            else { /* malformed — best-effort: advance past any '>' we find */
                size_t gt = src.find('>', pos); pos = (gt == std::string::npos) ? N : gt + 1;
            }
            intptr_t tagEnd = (intptr_t)pos;

            if (current) {
                current.contentEnd = tagStart;
                current.nodeEnd = tagEnd;
                // Pop up — even if names don't match (malformed), to avoid
                // runaway nesting. Name comparison is LOCAL (ignore namespace)
                // to be forgiving.
                current = current.parent;
            }
            continue;
        }

        // Start tag
        intptr_t openStart = (intptr_t)pos;
        ++pos;  // skip '<'
        std::string name = readName(src, pos);
        if (name.empty()) {
            // Not a tag after all (loose '<' in content). Skip.
            continue;
        }

        XNNode *node = [[XNNode alloc] init];
        node.name = [NSString stringWithUTF8String:name.c_str()];
        NSRange colon = [node.name rangeOfString:@":"];
        node.localName = (colon.location == NSNotFound) ? node.name
                            : [node.name substringFromIndex:colon.location + 1];
        node.nodeStart = openStart;
        if (pendingComment) {
            node.comment = pendingComment;
            pendingComment = nil;
        }

        // Attributes
        NSMutableArray<NSDictionary *> *attrs = [NSMutableArray array];
        while (pos < N) {
            pos = skipWS(src, pos);
            if (pos >= N) break;
            char c = src[pos];
            if (c == '/' || c == '>') break;
            std::string attrName = readName(src, pos);
            if (attrName.empty()) { ++pos; continue; }  // malformed — skip
            pos = skipWS(src, pos);
            std::string attrValue;
            if (pos < N && src[pos] == '=') {
                ++pos;
                pos = skipWS(src, pos);
                attrValue = readAttributeValue(src, pos);
            }
            [attrs addObject:@{
                @"name":  [NSString stringWithUTF8String:attrName.c_str()] ?: @"",
                @"value": [NSString stringWithUTF8String:attrValue.c_str()] ?: @""
            }];
        }
        node.attributes = attrs;

        // Self-closing?
        BOOL selfClosing = NO;
        if (pos < N && src[pos] == '/') { selfClosing = YES; ++pos; }
        if (pos < N && src[pos] == '>') ++pos;
        intptr_t openEnd = (intptr_t)pos;

        node.contentStart = openEnd;
        node.isEmpty = selfClosing;
        if (selfClosing) {
            node.contentEnd = openEnd;  // degenerate: no content
            node.nodeEnd = openEnd;
        }

        // Build display name: "localName [attrValue1] [attrValue2]…"
        NSMutableString *disp = [NSMutableString stringWithString:node.localName];
        if (attrs.count > 0) {
            [disp appendString:@" "];
            BOOL first = YES;
            for (NSDictionary *a in attrs) {
                if (!first) [disp appendString:@" "];
                [disp appendFormat:@"[%@]", a[@"value"]];
                first = NO;
            }
        }
        node.displayName = disp;

        // Parent / depth wiring
        if (current) {
            node.parent = current;
            node.depth = current.depth + 1;
            [current.children addObject:node];
        } else {
            node.depth = 0;
            if (root == nil) {
                root = node;
            } else {
                // Fragment with multiple top-level elements: synthesize a
                // common virtual parent so the tree stays single-rooted.
                if (!synthesizedRoot) {
                    synthesizedRoot = [[XNNode alloc] init];
                    synthesizedRoot.name = @"(fragments)";
                    synthesizedRoot.localName = @"(fragments)";
                    synthesizedRoot.displayName = @"(fragments)";
                    synthesizedRoot.nodeStart = root.nodeStart;
                    synthesizedRoot.contentStart = root.nodeStart;
                    [synthesizedRoot.children addObject:root];
                    root.parent = synthesizedRoot;
                    root = synthesizedRoot;
                }
                node.parent = synthesizedRoot;
                node.depth = 1;
                [synthesizedRoot.children addObject:node];
            }
        }

        if (!selfClosing) current = node;
    }

    result.root = root;
    return result;
}

} // namespace xmlscan

// ---------------------------------------------------------------------------
// Scintilla navigation helpers
// ---------------------------------------------------------------------------
// Scintilla's SCI_GRABFOCUS (2400) hands keyboard focus back to the editor
// widget. Critical when navigating from a docked panel — without it the
// caret moves at the byte level but Scintilla stays unfocused, so the
// caret is drawn dimmed (or invisibly) and the user sees nothing change.
// The floating-panel era didn't have this problem because the plugin
// window was separate and the main editor already owned key focus.
#ifndef SCI_GRABFOCUS
#  define SCI_GRABFOCUS 2400
#endif

static void gotoPosition(intptr_t position) {
    if (position < 0) return;
    sci(SCI_GOTOPOS, (uintptr_t)position);
    sci(SCI_SCROLLCARET);
    sci(SCI_GRABFOCUS);
}

static void setSelection(intptr_t startPos, intptr_t endPos) {
    if (startPos < 0 || endPos < 0) return;
    sci(SCI_SETSELECTIONSTART, (uintptr_t)startPos);
    sci(SCI_SETSELECTIONEND,   (uintptr_t)endPos);
    sci(SCI_SCROLLCARET);
    sci(SCI_GRABFOCUS);
}

// ---------------------------------------------------------------------------
// NavigatorPanel — content view (NSView). In v1.0.3+ the view is docked in
// the host's SidePanelHost via NPPM_DMM_REGISTERPANEL; on older hosts the
// plugin wraps it in a floating NSPanel instead. Both paths share this
// single class — it's just a content view either way.
//
// The panel no longer renders its own title bar or close X. In the docked
// path the host's PanelFrame provides both chrome elements; in the floating
// path the NSPanel's native title bar (NSWindowStyleMaskTitled +
// NSWindowStyleMaskClosable) does the same job. What remains here is the
// panel body: the filter row and the tree view.
// ---------------------------------------------------------------------------
@interface NavigatorPanel : NSView <NSOutlineViewDataSource, NSOutlineViewDelegate,
                                     NSTextFieldDelegate, NSMenuItemValidation>
@property(nonatomic, strong) NSTextField *filterField;
@property(nonatomic, strong) XNOutlineView *outlineView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) XNNode *rootNode;
@property(nonatomic, strong) NSArray<XNNode *> *topLevelNodes;  // cached filter result
@property(nonatomic, copy)   NSArray<NSString *> *filterTokens;
// Current row font size in points. User tunes via Cmd+= / Cmd+- / Cmd+0.
// Clamped to [kMinFontSize, kMaxFontSize]; reset returns to kDefaultFontSize.
@property(nonatomic, assign) CGFloat fontSize;
- (void)reload;
- (void)setDocumentText:(NSString *)text;
- (void)toggleDisclosureFromButton:(XNDiscView *)sender;
- (void)bumpFontSize:(CGFloat)delta;
- (void)resetFontSize;
// YES when the panel is attached to a window (docked host or floating
// fallback). Replaces the NSPanel isVisible check we used to rely on.
- (BOOL)isShown;
@end

// Row-height + font-size tuning constants. Kept small so the tree packs
// densely — matches the look of the Search Results Panel.
static const CGFloat kDefaultFontSize = 11.0;
static const CGFloat kMinFontSize     = 8.0;
static const CGFloat kMaxFontSize     = 28.0;
static const CGFloat kRowPadding      = 3.0;  // rowHeight = ceil(font size) + pad

@implementation NavigatorPanel

+ (instancetype)sharedPanel {
    static NavigatorPanel *panel = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Default frame — overridden by autolayout once added to a parent
        // (SidePanelHost stack sizes us automatically; floating NSPanel
        // wrapper gives us the window's content rect).
        panel = [[NavigatorPanel alloc] initWithFrame:NSMakeRect(0, 0, 280, 520)];
        panel.translatesAutoresizingMaskIntoConstraints = NO;
        [panel buildUI];
    });
    return panel;
}

- (BOOL)isShown {
    // Attached to a window AND has a superview = rendered somewhere.
    return self.window != nil && self.superview != nil;
}

- (void)buildUI {
    NSView *root = self;

    // Filter row — sits at the top of the panel body. Chrome (title bar,
    // close X, separator) is provided by the host's PanelFrame in the
    // docked path and by the NSPanel's native chrome in the floating path.
    _filterField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _filterField.translatesAutoresizingMaskIntoConstraints = NO;
    _filterField.placeholderString = @"Filter nodes…";
    _filterField.delegate = self;
    _filterField.bezelStyle = NSTextFieldRoundedBezel;
    [root addSubview:_filterField];

    // Outline view in a scroll view — use our XNOutlineView subclass so
    // the native triangle disappears and our +/- button takes its place.
    _fontSize = kDefaultFontSize;
    _outlineView = [[XNOutlineView alloc] initWithFrame:NSZeroRect];
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.headerView = nil;  // tree-only, no column header
    _outlineView.target = self;
    _outlineView.action = @selector(outlineViewSingleClicked:);
    _outlineView.focusRingType = NSFocusRingTypeNone;
    _outlineView.allowsMultipleSelection = NO;
    _outlineView.autoresizesOutlineColumn = NO;
    // Dense packing: smaller indent per level and near-zero intercell
    // spacing so rows sit close together. Row height follows the font.
    _outlineView.indentationPerLevel = 12.0;
    _outlineView.intercellSpacing = NSMakeSize(0, 0);
    _outlineView.rowHeight = MAX(13.0, ceil(_fontSize) + kRowPadding);
    _outlineView.gridStyleMask = NSTableViewGridNone;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.width = 380;
    col.minWidth = 80;
    col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    // No outer border — matches FunctionList / DocMap. The SidePanelHost
    // stack + window chrome provide all the visual separation we need.
    _scrollView.borderType = NSNoBorder;
    _scrollView.documentView = _outlineView;
    [root addSubview:_scrollView];

    // Context menu
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"Go to Node Start"     action:@selector(ctxGoToNodeStart:)     keyEquivalent:@""];
    [menu addItemWithTitle:@"Go to Node End"       action:@selector(ctxGoToNodeEnd:)       keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Go to Content Start"  action:@selector(ctxGoToContentStart:)  keyEquivalent:@""];
    [menu addItemWithTitle:@"Go to Content End"    action:@selector(ctxGoToContentEnd:)    keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Select Node"          action:@selector(ctxSelectNode:)        keyEquivalent:@""];
    [menu addItemWithTitle:@"Select Content"       action:@selector(ctxSelectContent:)     keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) item.target = self;
    _outlineView.menu = menu;

    // Layout: filter row at top → outline view fills the rest.
    // The filter field spans the full width; Esc on the field still clears
    // it (handled in controlTextDidChange:) so the old trailing ✕ button
    // was redundant and has been removed.
    [NSLayoutConstraint activateConstraints:@[
        [_filterField.topAnchor      constraintEqualToAnchor:root.topAnchor constant:4],
        [_filterField.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:6],
        [_filterField.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-6],
        [_filterField.heightAnchor   constraintEqualToConstant:22],

        // Outline fills the remaining space (flush to edges — no border)
        [_scrollView.topAnchor      constraintEqualToAnchor:_filterField.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor],
    ]];
}

// Re-read the active Scintilla buffer and rebuild the tree.
//
// NSOutlineView keeps weak references to the items returned from
// numberOfChildrenOfItem: / child:ofItem: and retains them across
// reloadData to preserve selection and expansion state. That's a problem
// when we replace the whole tree: after `self.rootNode = newTree`, the
// old XNNode objects may be deallocated while the outline view still
// holds pointers to them for its cached expansion state → a user click
// on an expand triangle sends objc_msgSend to freed memory → crash in
// -[NSOutlineView _nonStaticNumberOfChildrenOfItem:].
//
// Workaround: do a two-step reload. First present an empty data set and
// reloadData — NSOutlineView drops every cached item pointer because the
// tree is gone. Then swap in the new tree and reloadData again. The
// outline view picks up the new items with no stale refs left over.
- (void)reload {
    if (![self isShown]) return;

    // Parse first — this doesn't touch self state yet.
    std::string text = currentDocumentText();
    xmlscan::ParseResult r = xmlscan::parse(text);

    // Step 1: empty the outline view. NSOutlineView sees zero rows and
    // discards its expanded-items cache. Only after this is it safe to
    // drop the old tree.
    self.topLevelNodes = @[];
    [self.outlineView reloadData];

    // Step 2: install the new tree.
    self.rootNode = r.root;
    [self rebuildTopLevelCache];
    [self.outlineView reloadData];

    if (self.topLevelNodes.count == 1) {
        [self.outlineView expandItem:self.topLevelNodes.firstObject];
    }
}

- (void)setDocumentText:(NSString *)text {
    // Used only by tests; normally we pull from Scintilla directly.
    std::string s = text.UTF8String ?: "";
    xmlscan::ParseResult r = xmlscan::parse(s);
    self.rootNode = r.root;
    [self rebuildTopLevelCache];
    [self.outlineView reloadData];
}

- (void)rebuildTopLevelCache {
    if (!self.rootNode) { self.topLevelNodes = @[]; return; }
    if (self.filterTokens.count == 0) {
        self.topLevelNodes = @[ self.rootNode ];
        return;
    }
    // With a filter, only show subtrees that contain a matching node.
    if ([self.rootNode subtreeMatchesFilter:self.filterTokens])
        self.topLevelNodes = @[ self.rootNode ];
    else
        self.topLevelNodes = @[];
}

// Children for the filtered view: filter-aware pass-through
- (NSArray<XNNode *> *)filteredChildrenOf:(XNNode *)node {
    if (self.filterTokens.count == 0) return node.children;
    NSMutableArray *out = [NSMutableArray array];
    for (XNNode *c in node.children)
        if ([c subtreeMatchesFilter:self.filterTokens]) [out addObject:c];
    return out;
}

// ── NSOutlineViewDataSource ────────────────────────────────────────────
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)self.topLevelNodes.count;
    return (NSInteger)[self filteredChildrenOf:(XNNode *)item].count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return self.topLevelNodes[(NSUInteger)index];
    return [self filteredChildrenOf:(XNNode *)item][(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return [self filteredChildrenOf:(XNNode *)item].count > 0;
}

- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)col byItem:(id)item {
    XNNode *n = (XNNode *)item;
    if (n.comment.length > 0)
        return [NSString stringWithFormat:@"%@  // %@", n.displayName, n.comment];
    return n.displayName;
}

// ── NSOutlineViewDelegate ──────────────────────────────────────────────
//
// Cell layout (leading→trailing):
//   [+/− button, 12×12] gap [label, flex width]
// Leaf rows hide the button (hidden=YES) but keep the layout so labels
// across expandable and leaf rows line up vertically.
- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    XNCellView *cell = [ov makeViewWithIdentifier:@"XNCell" owner:self];
    if (!cell) {
        cell = [[XNCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"XNCell";

        XNDiscView *disc = [[XNDiscView alloc] initWithFrame:NSMakeRect(0, 0, 9, 9)];
        disc.translatesAutoresizingMaskIntoConstraints = NO;
        __weak typeof(self) weakSelf = self;
        __weak XNDiscView *weakDisc = disc;
        disc.onClick = ^{ [weakSelf toggleDisclosureFromButton:weakDisc]; };
        [cell addSubview:disc];
        cell.discButton = disc;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            // 9×9 compact disclosure box — matches the Search Results Panel
            // marker footprint. The box is flush to the leading edge of
            // the cell; NSOutlineView handles indentation by shifting the
            // whole cell.
            [disc.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor  constant:0],
            [disc.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [disc.widthAnchor   constraintEqualToConstant:9],
            [disc.heightAnchor  constraintEqualToConstant:9],

            [tf.leadingAnchor  constraintEqualToAnchor:disc.trailingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    XNNode *n = (XNNode *)item;
    NSString *text = n.displayName ?: @"";
    if (n.comment.length > 0) text = [NSString stringWithFormat:@"%@  // %@", text, n.comment];
    cell.textField.stringValue = text;
    cell.textField.toolTip = n.comment;
    cell.textField.font = [NSFont systemFontOfSize:self.fontSize];

    // Show the disclosure box only when the row is actually expandable
    // (leaf rows and filter-hidden subtrees hide it).
    BOOL expandable = [self filteredChildrenOf:n].count > 0;
    cell.discButton.hidden = !expandable;
    if (expandable) {
        cell.discButton.expanded = [ov isItemExpanded:n];
        [cell.discButton setNeedsDisplay:YES];
    }
    return cell;
}

// Maintain button titles when the user expands/collapses via the keyboard
// (arrow keys) so the +/- stays in sync with the outline view's state.
- (void)outlineViewItemDidExpand:(NSNotification *)note {
    [self refreshDiscButtonForItem:note.userInfo[@"NSObject"]];
}
- (void)outlineViewItemDidCollapse:(NSNotification *)note {
    [self refreshDiscButtonForItem:note.userInfo[@"NSObject"]];
}
- (void)refreshDiscButtonForItem:(id)item {
    if (!item) return;
    NSInteger row = [self.outlineView rowForItem:item];
    if (row < 0) return;
    NSView *v = [self.outlineView viewAtColumn:0 row:row makeIfNecessary:NO];
    if (![v isKindOfClass:[XNCellView class]]) return;
    XNCellView *cell = (XNCellView *)v;
    cell.discButton.expanded = [self.outlineView isItemExpanded:item];
    [cell.discButton setNeedsDisplay:YES];
}

// Disclosure click: walk up from the XNDiscView to find its row, then
// toggle that item's expansion. rowForView: keeps this valid across cell
// recycling (we never cache per-cell XNNode pointers).
- (void)toggleDisclosureFromButton:(XNDiscView *)sender {
    NSInteger row = [self.outlineView rowForView:sender];
    if (row < 0) return;
    id item = [self.outlineView itemAtRow:row];
    if (!item) return;
    if ([self.outlineView isItemExpanded:item]) {
        [self.outlineView collapseItem:item];
    } else {
        [self.outlineView expandItem:item];
    }
    // The outline view fires outlineViewItemDid{Expand,Collapse}: which
    // updates the indicator via refreshDiscButtonForItem: — but only when
    // state actually changed. Set it explicitly too so rapid clicks
    // track without depending on notification order.
    sender.expanded = [self.outlineView isItemExpanded:item];
    [sender setNeedsDisplay:YES];
}

// ── Font-size zoom (Cmd+= / Cmd+- / Cmd+0) ─────────────────────────────
- (void)setFontSize:(CGFloat)fontSize {
    CGFloat clamped = MAX(kMinFontSize, MIN(kMaxFontSize, fontSize));
    if (fabs(clamped - _fontSize) < 0.5) return;
    _fontSize = clamped;
    // Floor at 13 so the 12px +/- button always fits without clipping.
    self.outlineView.rowHeight = MAX(13.0, ceil(_fontSize) + kRowPadding);
    // reloadData preserves item identity → expansion state survives.
    [self.outlineView reloadData];
}
- (void)bumpFontSize:(CGFloat)delta { self.fontSize = self.fontSize + delta; }
- (void)resetFontSize                { self.fontSize = kDefaultFontSize; }

// Intercept Cmd+= / Cmd+- / Cmd+0 when the panel is key. Done via
// performKeyEquivalent: so the shortcut also fires when focus is in the
// filter field or the outline view — mirroring how the main app treats
// zoom shortcuts.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Only claim Cmd+=/Cmd+-/Cmd+0 when focus is actually inside this
    // panel. Otherwise — when the user is typing in the editor — we'd
    // hijack the main editor's own zoom shortcut because NSWindow walks
    // the entire view hierarchy looking for a key-equivalent handler.
    NSResponder *fr = self.window.firstResponder;
    BOOL focusedInPanel = NO;
    if ([fr isKindOfClass:[NSView class]]) {
        for (NSView *v = (NSView *)fr; v; v = v.superview) {
            if (v == self) { focusedInPanel = YES; break; }
        }
    }
    if (focusedInPanel &&
        (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) ==
            NSEventModifierFlagCommand) {
        NSString *c = event.charactersIgnoringModifiers ?: @"";
        if ([c isEqualToString:@"="] || [c isEqualToString:@"+"]) {
            [self bumpFontSize:+1]; return YES;
        }
        if ([c isEqualToString:@"-"]) {
            [self bumpFontSize:-1]; return YES;
        }
        if ([c isEqualToString:@"0"]) {
            [self resetFontSize]; return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

// Single-click: move caret to node start (matches Windows AfterSelect)
- (void)outlineViewSingleClicked:(NSOutlineView *)sender {
    NSInteger row = sender.clickedRow;
    if (row < 0) return;
    XNNode *n = [sender itemAtRow:row];
    if (n) gotoPosition(n.nodeStart);
}

// ── NSTextFieldDelegate ───────────────────────────────────────────────
- (void)controlTextDidChange:(NSNotification *)note {
    [self applyFilterFromField];
}

// Esc clears the field (same behavior the ✕ button used to provide).
- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)fieldEditor
    doCommandBySelector:(SEL)cmd {
    if (cmd == @selector(cancelOperation:) && control == self.filterField
            && self.filterField.stringValue.length) {
        self.filterField.stringValue = @"";
        [self applyFilterFromField];
        return YES;
    }
    return NO;
}

// Split out from controlTextDidChange: so we can invoke filter logic
// programmatically (the notification parameter is declared nonnull).
- (void)applyFilterFromField {
    NSString *text = [self.filterField.stringValue stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if (text.length == 0) {
        self.filterTokens = @[];
    } else {
        self.filterTokens = [text componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
    }
    [self rebuildTopLevelCache];
    [self.outlineView reloadData];
    if (self.topLevelNodes.count > 0 && self.filterTokens.count > 0) {
        [self.outlineView expandItem:nil expandChildren:YES];
    }
}

// ── Context menu ──────────────────────────────────────────────────────
- (XNNode *)selectedNode {
    NSInteger row = self.outlineView.selectedRow;
    if (row < 0) row = self.outlineView.clickedRow;
    if (row < 0) return nil;
    return [self.outlineView itemAtRow:row];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    XNNode *n = [self selectedNode];
    BOOL hasNode = (n != nil);
    BOOL hasContent = hasNode && !n.isEmpty && n.contentEnd > n.contentStart;
    SEL a = item.action;
    if (a == @selector(ctxGoToContentStart:) || a == @selector(ctxGoToContentEnd:) ||
        a == @selector(ctxSelectContent:))
        return hasContent;
    return hasNode;
}

- (void)ctxGoToNodeStart:(id)sender    { XNNode *n = [self selectedNode]; if (n) gotoPosition(n.nodeStart); }
- (void)ctxGoToNodeEnd:(id)sender      { XNNode *n = [self selectedNode]; if (n) gotoPosition(n.nodeEnd); }
- (void)ctxGoToContentStart:(id)sender { XNNode *n = [self selectedNode]; if (n && !n.isEmpty) gotoPosition(n.contentStart); }
- (void)ctxGoToContentEnd:(id)sender   { XNNode *n = [self selectedNode]; if (n && !n.isEmpty) gotoPosition(n.contentEnd); }
- (void)ctxSelectNode:(id)sender       { XNNode *n = [self selectedNode]; if (n) setSelection(n.nodeStart, n.nodeEnd); }
- (void)ctxSelectContent:(id)sender    { XNNode *n = [self selectedNode]; if (n && !n.isEmpty) setSelection(n.contentStart, n.contentEnd); }

@end

// ---------------------------------------------------------------------------
// Docking layer — chooses between host-docked (NPPM_DMM_*) and floating
// NSPanel fallback based on host support.
//
// Docked path (v1.0.3+): call NPPM_DMM_REGISTERPANEL once; if it returns
// a nonzero handle the host has the docking API and we route all
// show/hide through handle-based messages. NppPluginManager owns the
// strong retain on the NSView.
//
// Floating path (older hosts): create an NSPanel once and use its
// contentView slot to hold the NavigatorPanel. Same UX as before ARC.
//
// Both paths use the same NavigatorPanel instance — the view is simply
// reparented between the side-panel stack and the floating NSPanel's
// content slot.
// ---------------------------------------------------------------------------

static uint64_t  g_panelHandle   = 0;     // nonzero → docked path active
static NSPanel  *g_floatingPanel = nil;   // only used when docking unavailable

// Build (lazily) the floating NSPanel used as a fallback when the host
// doesn't support NPPM_DMM_*. The NavigatorPanel view is installed as the
// panel's content view.
static NSPanel *ensureFloatingPanel(void) {
    if (g_floatingPanel) return g_floatingPanel;

    NSRect frame = NSMakeRect(0, 0, 420, 520);
    NSUInteger mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable |
                      NSWindowStyleMaskUtilityWindow;
    g_floatingPanel = [[NSPanel alloc] initWithContentRect:frame
                                                 styleMask:mask
                                                   backing:NSBackingStoreBuffered
                                                     defer:YES];
    g_floatingPanel.title = @"XML Navigator";
    g_floatingPanel.floatingPanel = YES;
    g_floatingPanel.becomesKeyOnlyIfNeeded = YES;
    g_floatingPanel.hidesOnDeactivate = NO;
    g_floatingPanel.releasedWhenClosed = NO;

    NavigatorPanel *view = [NavigatorPanel sharedPanel];
    // Mirror autoresizing so the view fills the panel as it resizes.
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.frame = ((NSView *)g_floatingPanel.contentView).bounds;
    [g_floatingPanel.contentView addSubview:view];
    [g_floatingPanel center];
    return g_floatingPanel;
}

static void xmlNavigatorShowPanel(void) {
    @autoreleasepool {
        g_panel = [NavigatorPanel sharedPanel];

        // First-time registration against the docking API. nppData is set
        // by setInfo which runs before NPPN_READY, so by the time the user
        // clicks our menu item the send-message function pointer is live.
        if (g_panelHandle == 0 && g_floatingPanel == nil) {
            intptr_t h = nppData._sendMessage(nppData._nppHandle,
                                              NPPM_DMM_REGISTERPANEL,
                                              (uintptr_t)(__bridge void *)g_panel,
                                              (intptr_t)"XML Navigator");
            if (h > 0) {
                g_panelHandle = (uint64_t)h;
            } else {
                // Older host — fall back to floating NSPanel. The NavigatorPanel
                // view becomes the panel's contentView once and stays there.
                ensureFloatingPanel();
            }
        }

        if (g_panelHandle > 0) {
            nppData._sendMessage(nppData._nppHandle,
                                 NPPM_DMM_SHOWPANEL,
                                 (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel makeKeyAndOrderFront:nil];
        }

        [g_panel reload];
    }
}

static void xmlNavigatorHidePanel(void) {
    @autoreleasepool {
        if (g_panelHandle > 0) {
            nppData._sendMessage(nppData._nppHandle,
                                 NPPM_DMM_HIDEPANEL,
                                 (uintptr_t)g_panelHandle, 0);
        } else if (g_floatingPanel) {
            [g_floatingPanel orderOut:nil];
        }
    }
}

static BOOL xmlNavigatorPanelIsShown(void) {
    if (g_panelHandle > 0) return g_panel && [g_panel isShown];
    if (g_floatingPanel) return g_floatingPanel.visible;
    return NO;
}

// ---------------------------------------------------------------------------
// Menu callbacks
// ---------------------------------------------------------------------------
// Toggle semantics: if the panel is shown, hide it; otherwise show it.
// This matches user expectation from native side panel toggles elsewhere
// in Notepad++ (Function List, Document List, etc.).
static void cmdShowNavigator() {
    if (xmlNavigatorPanelIsShown())
        xmlNavigatorHidePanel();
    else
        xmlNavigatorShowPanel();
}

static void cmdAbout() {
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"XML Navigator";
        alert.informativeText =
            @"Version 1.0 (macOS port)\n\n"
            "Tree-view navigator for XML documents. Click any node to jump\n"
            "to its position in the editor; right-click for more options.\n\n"
            "Original Windows plugin by Christian Grasser (archived).";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

// ---------------------------------------------------------------------------
// Plugin exports
// ---------------------------------------------------------------------------
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));

    strcpy(funcItem[IdxShowNavigator]._itemName, "Show XML Navigator");
    funcItem[IdxShowNavigator]._pFunc = cmdShowNavigator;

    strcpy(funcItem[IdxAbout]._itemName, "About");
    funcItem[IdxAbout]._pFunc = cmdAbout;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_TBMODIFICATION:
            // Register our toolbar icon. The host looks for toolbar.png at
            // the plugin's install-dir root (same folder as the dylib),
            // which is where `Build + package` places it. Binds the icon
            // to the Show-navigator menu command so clicking the toolbar
            // button toggles the panel.
            nppData._sendMessage(nppData._nppHandle,
                                 NPPM_ADDTOOLBARICON_FORDARKMODE,
                                 (uintptr_t)funcItem[IdxShowNavigator]._cmdID,
                                 (intptr_t)"toolbar.png");
            break;
        case NPPN_BUFFERACTIVATED:
        case NPPN_FILESAVED:
            // Auto-refresh when the active buffer changes or is saved.
            if (xmlNavigatorPanelIsShown()) [g_panel reload];
            break;
        case SCN_MODIFIED: {
            // Re-parse after edits that change text, but only when the panel
            // is visible. We could debounce here for very large docs; in
            // practice the tokenizer is fast enough for files up to a few
            // megabytes.
            if (!xmlNavigatorPanelIsShown()) break;
            int mod = n->modificationType;
            if (mod & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
                [g_panel reload];
            }
            break;
        }
        case NPPN_SHUTDOWN:
            // Release our docking-API registration so the host can drop its
            // strong retain on the view before dylib teardown. Harmless if
            // we never registered (floating-fallback path).
            if (g_panelHandle > 0) {
                nppData._sendMessage(nppData._nppHandle,
                                     NPPM_DMM_UNREGISTERPANEL,
                                     (uintptr_t)g_panelHandle, 0);
                g_panelHandle = 0;
            }
            break;
        default: break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
